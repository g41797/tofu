///////////////////////////////////////////////////////////////////////////////////////////////
//                 AI Overview
//
// A multihomed TCP/IP server is a server with multiple network connections
// (network interface cards) and IP addresses, allowing it to connect to
// and provide services on multiple networks simultaneously.
//
// This configuration enhances reliability and performance by providing redundancy
// and allowing direct access to different subnets for services like file sharing or databases.
//
// Key characteristics
//
//     Multiple network interfaces:
//         The server has more than one physical network adapter or is configured
//         with multiple IP addresses on a single adapter.
//
//     Connection to multiple networks:
//         It can be attached to several physical networks or subnets at the same time.
//
//     Host, not a router:
//         By default, a multihomed machine is not a router.
//         It does not forward packets between its interfaces.
//
//     Service accessibility:
//         It can provide services to clients on different networks directly,
//         without the need for a router to forward traffic to it.
//
// Use cases
//
//     High-performance servers:
//         Servers like those for NFS or databases can have multiple network cards
//         to improve file sharing or data access for a large pool of users across different networks.
//
//     Redundancy:
//         Having multiple network connections can provide redundancy.
//         If one connection fails, the other can still provide access to the server's services.
//
// Configuration
//
//     A server can have multiple IP addresses, either by adding new network cards
//     or by configuring multiple IP addresses on a single network card.
//
//     For some services, you can explicitly configure the service to bind to a specific
//     IP address on a particular network interface.
//
///////////////////////////////////////////////////////////////////////////////////////////////

pub const MultiHomed = @This();

const std = @import("std");
const Allocator = std.mem.Allocator;
const log = std.log;
const assert = std.debug.assert;

pub const tofu = @import("tofu");
pub const Engine = tofu.Engine;
pub const Ampe = tofu.Ampe;
pub const Channels = tofu.Channels;
pub const Options = tofu.Options;
pub const DefaultOptions = tofu.DefaultOptions;
pub const configurator = tofu.configurator;
pub const Configurator = configurator.Configurator;
pub const status = tofu.status;
pub const message = tofu.message;
pub const BinaryHeader = message.BinaryHeader;
pub const Message = message.Message;
