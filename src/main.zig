const std = @import("std");
const posix = std.posix;

const max_datagram_size = 65_507;

pub const UdpEchoServer = struct {
    socket: posix.socket_t,
    address: std.net.Address,

    pub fn init(bind_address: std.net.Address) !UdpEchoServer {
        const socket = try posix.socket(bind_address.any.family, posix.SOCK.DGRAM, posix.IPPROTO.UDP);
        errdefer posix.close(socket);

        try posix.setsockopt(socket, posix.SOL.SOCKET, posix.SO.REUSEADDR, &std.mem.toBytes(@as(c_int, 1)));
        try posix.bind(socket, &bind_address.any, bind_address.getOsSockLen());

        var actual_address = bind_address;
        var actual_address_len = actual_address.getOsSockLen();
        try posix.getsockname(socket, &actual_address.any, &actual_address_len);

        return .{
            .socket = socket,
            .address = actual_address,
        };
    }

    pub fn deinit(self: *UdpEchoServer) void {
        posix.close(self.socket);
    }

    pub fn run(self: *UdpEchoServer, max_packets: ?usize) !void {
        var served_packets: usize = 0;
        var buffer: [max_datagram_size]u8 = undefined;

        while (max_packets == null or served_packets < max_packets.?) {
            var client_address: posix.sockaddr = undefined;
            var client_address_len: posix.socklen_t = @sizeOf(posix.sockaddr);
            const received = try posix.recvfrom(
                self.socket,
                &buffer,
                0,
                &client_address,
                &client_address_len,
            );

            var sent: usize = 0;
            while (sent < received) {
                sent += try posix.sendto(
                    self.socket,
                    buffer[sent..received],
                    0,
                    &client_address,
                    client_address_len,
                );
            }

            served_packets += 1;
        }
    }
};

pub fn main() !void {
    var args = std.process.args();
    _ = args.skip();

    const host = args.next() orelse "127.0.0.1";
    const port_text = args.next() orelse "9000";
    const port = try std.fmt.parseInt(u16, port_text, 10);
    const bind_address = try std.net.Address.parseIp(host, port);

    var server = try UdpEchoServer.init(bind_address);
    defer server.deinit();

    std.log.info("UDP echo server listening on {}", .{server.address});
    try server.run(null);
}

fn runOnePacket(server: *UdpEchoServer, result: *?anyerror!void) void {
    result.* = server.run(1);
}

test "UDP echo server echoes one datagram" {
    const testing = std.testing;

    var server = try UdpEchoServer.init(try std.net.Address.parseIp("127.0.0.1", 0));
    defer server.deinit();

    var server_result: ?anyerror!void = null;
    const thread = try std.Thread.spawn(.{}, runOnePacket, .{ &server, &server_result });

    const client = try posix.socket(posix.AF.INET, posix.SOCK.DGRAM, posix.IPPROTO.UDP);
    defer posix.close(client);

    const message = "hello over udp";
    const sent = try posix.sendto(client, message, 0, &server.address.any, server.address.getOsSockLen());
    try testing.expectEqual(message.len, sent);

    var buffer: [128]u8 = undefined;
    const received = try posix.recvfrom(client, &buffer, 0, null, null);
    try testing.expectEqualStrings(message, buffer[0..received]);

    thread.join();
    try (server_result orelse error.ServerDidNotRun);
}
