const std = @import("std");
const catalog = @import("catalog.zig");
const row = @import("row.zig");
const db_mod = @import("db.zig");

pub const Statement = union(enum) {
    create_table: CreateTable,
    insert: Insert,
    select: Select,
    delete: Delete,

    pub fn deinit(self: *Statement, allocator: std.mem.Allocator) void {
        switch (self.*) {
            .create_table => |*statement| statement.deinit(allocator),
            .insert => |*statement| statement.deinit(allocator),
            .select => {},
            .delete => {},
        }
        self.* = undefined;
    }
};

pub const ColumnDef = struct {
    name: []const u8,
    column_type: catalog.ColumnType,
    primary_key: bool,
};

pub const CreateTable = struct {
    table_name: []const u8,
    columns: []ColumnDef,

    fn deinit(self: *CreateTable, allocator: std.mem.Allocator) void {
        allocator.free(self.columns);
        self.* = undefined;
    }
};

pub const Insert = struct {
    table_name: []const u8,
    columns: []const []const u8,
    values: []const []const u8,

    fn deinit(self: *Insert, allocator: std.mem.Allocator) void {
        allocator.free(self.columns);
        allocator.free(self.values);
        self.* = undefined;
    }
};

pub const Select = struct {
    table_name: []const u8,
    where_eq: ?WhereEq,
};

pub const Delete = struct {
    table_name: []const u8,
    where_column: []const u8,
    where_value: []const u8,
};

pub const WhereEq = struct {
    column: []const u8,
    value: []const u8,
};

pub fn parse(allocator: std.mem.Allocator, sql: []const u8) !Statement {
    var parser = Parser{ .allocator = allocator, .tokenizer = Tokenizer{ .input = sql } };
    return try parser.parse();
}

pub fn execute(allocator: std.mem.Allocator, db: *db_mod.Database, sql: []const u8) ![]u8 {
    var statement = try parse(allocator, sql);
    defer statement.deinit(allocator);

    return switch (statement) {
        .create_table => |create_table| try executeCreateTable(allocator, db, create_table),
        .insert => |insert| try executeInsert(allocator, db, insert),
        .select => |select| try executeSelect(allocator, db, select),
        .delete => |delete| try executeDelete(allocator, db, delete),
    };
}

fn executeCreateTable(allocator: std.mem.Allocator, db: *db_mod.Database, statement: CreateTable) ![]u8 {
    const key = try catalog.catalogKey(allocator, statement.table_name);
    defer allocator.free(key);

    if (try db.get(allocator, key)) |existing| {
        allocator.free(existing);
        return error.TableAlreadyExists;
    }

    var primary_key_count: usize = 0;
    const table_name = try allocator.dupe(u8, statement.table_name);
    errdefer allocator.free(table_name);
    const columns = try allocator.alloc(catalog.Column, statement.columns.len);
    var initialized: usize = 0;
    errdefer {
        for (columns[0..initialized]) |*column| allocator.free(column.name);
        allocator.free(columns);
    }

    for (statement.columns, 0..) |column, index| {
        if (column.primary_key) primary_key_count += 1;
        columns[index] = .{
            .name = try allocator.dupe(u8, column.name),
            .column_type = column.column_type,
            .primary_key = column.primary_key,
        };
        initialized += 1;
    }

    if (primary_key_count != 1) return error.InvalidPrimaryKey;
    var schema = catalog.TableSchema{ .name = table_name, .columns = columns };
    defer schema.deinit(allocator);

    const encoded = try catalog.encodeSchema(allocator, schema);
    defer allocator.free(encoded);
    try db.put(key, encoded);
    return try allocator.dupe(u8, "OK\n");
}

fn executeInsert(allocator: std.mem.Allocator, db: *db_mod.Database, statement: Insert) ![]u8 {
    var schema = try loadSchema(allocator, db, statement.table_name);
    defer schema.deinit(allocator);

    if (statement.columns.len != statement.values.len) return error.ColumnValueCountMismatch;
    if (statement.columns.len != schema.columns.len) return error.MissingColumn;

    const values = try allocator.alloc([]const u8, schema.columns.len);
    defer allocator.free(values);
    const seen = try allocator.alloc(bool, schema.columns.len);
    defer allocator.free(seen);
    @memset(seen, false);

    for (statement.columns, statement.values) |column_name, value| {
        const index = try schema.columnIndex(column_name);
        if (seen[index]) return error.DuplicateColumn;
        seen[index] = true;
        values[index] = value;
    }
    for (seen) |is_seen| {
        if (!is_seen) return error.MissingColumn;
    }

    const pk_index = try schema.primaryKeyIndex();
    const key = try catalog.rowKey(allocator, schema.name, values[pk_index]);
    defer allocator.free(key);

    const encoded = try row.encode(allocator, values);
    defer allocator.free(encoded);
    try db.put(key, encoded);
    return try allocator.dupe(u8, "OK\n");
}

fn executeSelect(allocator: std.mem.Allocator, db: *db_mod.Database, statement: Select) ![]u8 {
    var schema = try loadSchema(allocator, db, statement.table_name);
    defer schema.deinit(allocator);

    var output: std.ArrayList(u8) = .empty;
    errdefer output.deinit(allocator);
    try appendHeader(allocator, &output, schema);

    if (statement.where_eq) |where_eq| {
        try validatePrimaryKeyWhere(&schema, where_eq.column);
        const key = try catalog.rowKey(allocator, schema.name, where_eq.value);
        defer allocator.free(key);

        if (try db.get(allocator, key)) |encoded_row| {
            defer allocator.free(encoded_row);
            try appendEncodedRow(allocator, &output, schema, encoded_row);
        }
        return try output.toOwnedSlice(allocator);
    }

    const start_key = try catalog.rowPrefix(allocator, schema.name);
    defer allocator.free(start_key);
    const end_key = try catalog.rowRangeEndKey(allocator, schema.name);
    defer allocator.free(end_key);

    const pairs = try db.scan(allocator, start_key, end_key, null);
    defer {
        for (pairs) |*pair| pair.deinit(allocator);
        allocator.free(pairs);
    }
    for (pairs) |pair| try appendEncodedRow(allocator, &output, schema, pair.value);

    return try output.toOwnedSlice(allocator);
}

fn executeDelete(allocator: std.mem.Allocator, db: *db_mod.Database, statement: Delete) ![]u8 {
    var schema = try loadSchema(allocator, db, statement.table_name);
    defer schema.deinit(allocator);
    try validatePrimaryKeyWhere(&schema, statement.where_column);

    const key = try catalog.rowKey(allocator, schema.name, statement.where_value);
    defer allocator.free(key);
    _ = try db.delete(key);
    return try allocator.dupe(u8, "OK\n");
}

fn loadSchema(allocator: std.mem.Allocator, db: *db_mod.Database, table_name: []const u8) !catalog.TableSchema {
    const key = try catalog.catalogKey(allocator, table_name);
    defer allocator.free(key);
    const encoded = try db.get(allocator, key) orelse return error.UnknownTable;
    defer allocator.free(encoded);
    return try catalog.decodeSchema(allocator, encoded);
}

fn validatePrimaryKeyWhere(schema: *const catalog.TableSchema, column_name: []const u8) !void {
    const where_index = try schema.columnIndex(column_name);
    const pk_index = try schema.primaryKeyIndex();
    if (where_index != pk_index) return error.UnsupportedWhere;
}

fn appendHeader(allocator: std.mem.Allocator, output: *std.ArrayList(u8), schema: catalog.TableSchema) !void {
    for (schema.columns, 0..) |column, index| {
        if (index != 0) try output.append(allocator, '\t');
        try output.appendSlice(allocator, column.name);
    }
    try output.append(allocator, '\n');
}

fn appendValues(allocator: std.mem.Allocator, output: *std.ArrayList(u8), values: []const []const u8) !void {
    for (values, 0..) |value, index| {
        if (index != 0) try output.append(allocator, '\t');
        try output.appendSlice(allocator, value);
    }
    try output.append(allocator, '\n');
}

fn appendEncodedRow(allocator: std.mem.Allocator, output: *std.ArrayList(u8), schema: catalog.TableSchema, encoded_row: []const u8) !void {
    var decoded = try row.decode(allocator, encoded_row);
    defer decoded.deinit(allocator);
    if (decoded.values.len != schema.columns.len) return error.CorruptRow;
    try appendValues(allocator, output, decoded.values);
}

const TokenTag = enum {
    identifier,
    string,
    lparen,
    rparen,
    comma,
    semicolon,
    star,
    eq,
    eof,
};

const Token = struct {
    tag: TokenTag,
    lexeme: []const u8,
};

const Tokenizer = struct {
    input: []const u8,
    index: usize = 0,

    fn next(self: *Tokenizer) !Token {
        self.skipWhitespace();
        if (self.index >= self.input.len) return .{ .tag = .eof, .lexeme = "" };

        const start = self.index;
        const c = self.input[self.index];
        self.index += 1;
        return switch (c) {
            '(' => .{ .tag = .lparen, .lexeme = self.input[start..self.index] },
            ')' => .{ .tag = .rparen, .lexeme = self.input[start..self.index] },
            ',' => .{ .tag = .comma, .lexeme = self.input[start..self.index] },
            ';' => .{ .tag = .semicolon, .lexeme = self.input[start..self.index] },
            '*' => .{ .tag = .star, .lexeme = self.input[start..self.index] },
            '=' => .{ .tag = .eq, .lexeme = self.input[start..self.index] },
            '\'' => try self.stringToken(start),
            else => {
                if (!isIdentifierStart(c)) return error.UnexpectedToken;
                while (self.index < self.input.len and isIdentifierPart(self.input[self.index])) {
                    self.index += 1;
                }
                return .{ .tag = .identifier, .lexeme = self.input[start..self.index] };
            },
        };
    }

    fn stringToken(self: *Tokenizer, start: usize) !Token {
        const content_start = self.index;
        while (self.index < self.input.len and self.input[self.index] != '\'') {
            self.index += 1;
        }
        if (self.index >= self.input.len) return error.UnterminatedString;
        const content = self.input[content_start..self.index];
        self.index += 1;
        _ = start;
        return .{ .tag = .string, .lexeme = content };
    }

    fn skipWhitespace(self: *Tokenizer) void {
        while (self.index < self.input.len and std.ascii.isWhitespace(self.input[self.index])) {
            self.index += 1;
        }
    }
};

const Parser = struct {
    allocator: std.mem.Allocator,
    tokenizer: Tokenizer,
    peeked: ?Token = null,

    fn parse(self: *Parser) !Statement {
        const first = try self.peek();
        if (first.tag != .identifier) return error.ExpectedStatement;

        const statement = if (keyword(first.lexeme, "CREATE"))
            try self.parseCreateTable()
        else if (keyword(first.lexeme, "INSERT"))
            try self.parseInsert()
        else if (keyword(first.lexeme, "SELECT"))
            try self.parseSelect()
        else if (keyword(first.lexeme, "DELETE"))
            try self.parseDelete()
        else
            return error.ExpectedStatement;

        try self.consumeOptionalSemicolon();
        try self.expect(.eof);
        return statement;
    }

    fn parseCreateTable(self: *Parser) !Statement {
        try self.expectKeyword("CREATE");
        try self.expectKeyword("TABLE");
        const table_name = try self.expectIdentifier();
        try self.expect(.lparen);

        var columns: std.ArrayList(ColumnDef) = .empty;
        errdefer columns.deinit(self.allocator);
        var primary_key_count: usize = 0;
        while (true) {
            const name = try self.expectIdentifier();
            const column_type = try self.parseColumnType();
            var primary_key = false;
            if (try self.eatKeyword("PRIMARY")) {
                try self.expectKeyword("KEY");
                primary_key = true;
                primary_key_count += 1;
            }
            try columns.append(self.allocator, .{ .name = name, .column_type = column_type, .primary_key = primary_key });

            if (try self.eat(.comma)) continue;
            break;
        }
        try self.expect(.rparen);
        if (primary_key_count != 1) return error.InvalidPrimaryKey;

        return .{ .create_table = .{
            .table_name = table_name,
            .columns = try columns.toOwnedSlice(self.allocator),
        } };
    }

    fn parseInsert(self: *Parser) !Statement {
        try self.expectKeyword("INSERT");
        try self.expectKeyword("INTO");
        const table_name = try self.expectIdentifier();
        const columns = try self.parseIdentifierList();
        errdefer self.allocator.free(columns);
        try self.expectKeyword("VALUES");
        const values = try self.parseStringList();
        errdefer self.allocator.free(values);
        return .{ .insert = .{ .table_name = table_name, .columns = columns, .values = values } };
    }

    fn parseSelect(self: *Parser) !Statement {
        try self.expectKeyword("SELECT");
        try self.expect(.star);
        try self.expectKeyword("FROM");
        const table_name = try self.expectIdentifier();
        const where_eq = if (try self.eatKeyword("WHERE")) try self.parseWhereEq() else null;
        return .{ .select = .{ .table_name = table_name, .where_eq = where_eq } };
    }

    fn parseDelete(self: *Parser) !Statement {
        try self.expectKeyword("DELETE");
        try self.expectKeyword("FROM");
        const table_name = try self.expectIdentifier();
        try self.expectKeyword("WHERE");
        const where = try self.parseWhereEq();
        return .{ .delete = .{ .table_name = table_name, .where_column = where.column, .where_value = where.value } };
    }

    fn parseColumnType(self: *Parser) !catalog.ColumnType {
        const token = try self.expectIdentifier();
        if (keyword(token, "TEXT")) return .text;
        return error.UnsupportedColumnType;
    }

    fn parseIdentifierList(self: *Parser) ![]const []const u8 {
        try self.expect(.lparen);
        var items: std.ArrayList([]const u8) = .empty;
        errdefer items.deinit(self.allocator);
        while (true) {
            try items.append(self.allocator, try self.expectIdentifier());
            if (try self.eat(.comma)) continue;
            break;
        }
        try self.expect(.rparen);
        return try items.toOwnedSlice(self.allocator);
    }

    fn parseStringList(self: *Parser) ![]const []const u8 {
        try self.expect(.lparen);
        var items: std.ArrayList([]const u8) = .empty;
        errdefer items.deinit(self.allocator);
        while (true) {
            try items.append(self.allocator, try self.expectString());
            if (try self.eat(.comma)) continue;
            break;
        }
        try self.expect(.rparen);
        return try items.toOwnedSlice(self.allocator);
    }

    fn parseWhereEq(self: *Parser) !WhereEq {
        const column = try self.expectIdentifier();
        try self.expect(.eq);
        const value = try self.expectString();
        return .{ .column = column, .value = value };
    }

    fn expectKeyword(self: *Parser, expected: []const u8) !void {
        const token = try self.next();
        if (token.tag != .identifier or !keyword(token.lexeme, expected)) return error.UnexpectedToken;
    }

    fn eatKeyword(self: *Parser, expected: []const u8) !bool {
        const token = try self.peek();
        if (token.tag == .identifier and keyword(token.lexeme, expected)) {
            _ = try self.next();
            return true;
        }
        return false;
    }

    fn expectIdentifier(self: *Parser) ![]const u8 {
        const token = try self.next();
        if (token.tag != .identifier) return error.ExpectedIdentifier;
        return token.lexeme;
    }

    fn expectString(self: *Parser) ![]const u8 {
        const token = try self.next();
        if (token.tag != .string) return error.ExpectedString;
        return token.lexeme;
    }

    fn expect(self: *Parser, tag: TokenTag) !void {
        const token = try self.next();
        if (token.tag != tag) return error.UnexpectedToken;
    }

    fn eat(self: *Parser, tag: TokenTag) !bool {
        const token = try self.peek();
        if (token.tag == tag) {
            _ = try self.next();
            return true;
        }
        return false;
    }

    fn consumeOptionalSemicolon(self: *Parser) !void {
        _ = try self.eat(.semicolon);
    }

    fn peek(self: *Parser) !Token {
        if (self.peeked == null) self.peeked = try self.tokenizer.next();
        return self.peeked.?;
    }

    fn next(self: *Parser) !Token {
        if (self.peeked) |token| {
            self.peeked = null;
            return token;
        }
        return try self.tokenizer.next();
    }
};

fn keyword(actual: []const u8, expected: []const u8) bool {
    return std.ascii.eqlIgnoreCase(actual, expected);
}

fn isIdentifierStart(c: u8) bool {
    return std.ascii.isAlphabetic(c) or c == '_';
}

fn isIdentifierPart(c: u8) bool {
    return std.ascii.isAlphanumeric(c) or c == '_';
}

test "SQL parser handles create table" {
    var statement = try parse(std.testing.allocator, "CREATE TABLE users (id TEXT PRIMARY KEY, name TEXT);");
    defer statement.deinit(std.testing.allocator);
    try std.testing.expectEqualStrings("users", statement.create_table.table_name);
    try std.testing.expectEqual(@as(usize, 2), statement.create_table.columns.len);
    try std.testing.expect(statement.create_table.columns[0].primary_key);
}

test "SQL execute create insert select delete and reopen" {
    const allocator = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const file = try tmp.dir.createFile(std.testing.io, "sql.db", .{ .read = true });
    file.close(std.testing.io);
    const path = try std.fmt.allocPrint(allocator, ".zig-cache/tmp/{s}/sql.db", .{tmp.sub_path});
    defer allocator.free(path);

    var db = try db_mod.Database.open(allocator, path, 64);
    var result = try execute(allocator, &db, "CREATE TABLE users (id TEXT PRIMARY KEY, name TEXT);");
    allocator.free(result);
    result = try execute(allocator, &db, "INSERT INTO users (id, name) VALUES ('1', 'Alice');");
    allocator.free(result);
    result = try execute(allocator, &db, "INSERT INTO users (id, name) VALUES ('2', 'Bob');");
    allocator.free(result);
    result = try execute(allocator, &db, "SELECT * FROM users WHERE id = '1';");
    try std.testing.expectEqualStrings("id\tname\n1\tAlice\n", result);
    allocator.free(result);
    result = try execute(allocator, &db, "SELECT * FROM users;");
    defer allocator.free(result);
    try std.testing.expectEqualStrings("id\tname\n1\tAlice\n2\tBob\n", result);
    try db.close();

    var reopened = try db_mod.Database.open(allocator, path, 64);
    defer reopened.close() catch unreachable;
    const persisted = try execute(allocator, &reopened, "SELECT * FROM users WHERE id = '1';");
    defer allocator.free(persisted);
    try std.testing.expectEqualStrings("id\tname\n1\tAlice\n", persisted);

    const deleted = try execute(allocator, &reopened, "DELETE FROM users WHERE id = '1';");
    allocator.free(deleted);
    const empty = try execute(allocator, &reopened, "SELECT * FROM users WHERE id = '1';");
    defer allocator.free(empty);
    try std.testing.expectEqualStrings("id\tname\n", empty);
}
