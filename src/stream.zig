/// abstract tls behind reader and writer
const std = @import("std");

net_stream: std.net.Stream,
tls_client: ?std.crypto.tls.Client,

const Self = @This();
const io = std.io;

pub const ReadError = error{
    SystemResources,
    Unexpected,
    WouldBlock,
    ConnectionResetByPeer,
    AccessDenied,
    InputOutput,
    OperationAborted,
    BrokenPipe,
    Overflow,
    ConnectionTimedOut,
    IsDir,
    NotOpenForReading,
    SocketNotConnected,
    NetNameDeleted,
    TlsAlertUnexpectedMessage,
    TlsAlertBadRecordMac,
    TlsAlertRecordOverflow,
    TlsAlertHandshakeFailure,
    TlsAlertBadCertificate,
    TlsAlertUnsupportedCertificate,
    TlsAlertCertificateRevoked,
    TlsAlertCertificateExpired,
    TlsAlertCertificateUnknown,
    TlsAlertIllegalParameter,
    TlsAlertUnknownCa,
    TlsAlertAccessDenied,
    TlsAlertDecodeError,
    TlsAlertDecryptError,
    TlsAlertProtocolVersion,
    TlsAlertInsufficientSecurity,
    TlsAlertInternalError,
    TlsAlertInappropriateFallback,
    TlsAlertMissingExtension,
    TlsAlertUnsupportedExtension,
    TlsAlertUnrecognizedName,
    TlsAlertBadCertificateStatusResponse,
    TlsAlertUnknownPskIdentity,
    TlsAlertCertificateRequired,
    TlsAlertNoApplicationProtocol,
    TlsAlertUnknown,
    TlsUnexpectedMessage,
    TlsIllegalParameter,
    TlsRecordOverflow,
    TlsBadRecordMac,
    TlsConnectionTruncated,
    TlsDecodeError,
    TlsBadLength,
};
pub const WriteError = error{
    SystemResources,
    Unexpected,
    WouldBlock,
    ConnectionResetByPeer,
    AccessDenied,
    FileTooBig,
    NoSpaceLeft,
    DeviceBusy,
    InputOutput,
    OperationAborted,
    BrokenPipe,
    DiskQuota,
    InvalidArgument,
    NotOpenForWriting,
    LockViolation,
};

pub const Reader = io.Reader(*Self, ReadError, read);
pub const Writer = io.Writer(*Self, WriteError, write);

pub fn reader(self: *Self) Reader {
    return .{ .context = self };
}

pub fn writer(self: *Self) Writer {
    return .{ .context = self };
}

pub fn read(self: *Self, dest: []u8) ReadError!usize {
    if (self.tls_client) |*t| return try t.read(self.net_stream, dest);

    return try self.net_stream.read(dest);
}

pub fn write(self: *Self, bytes: []const u8) WriteError!usize {
    if (self.tls_client) |*t| return try t.write(self.net_stream, bytes);

    return try self.net_stream.write(bytes);
}

pub fn close(self: *Self) void {
    if (self.tls_client) |*t| _ = t.writeEnd(self.net_stream, "", true) catch {};
    self.net_stream.close();
}
