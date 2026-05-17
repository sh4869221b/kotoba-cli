const std = @import("std");
const config = @import("config.zig");
const errors = @import("errors.zig");
const llama = @import("llama.zig");
const sys = @import("sys.zig");
const xdg = @import("xdg.zig");

const c = @cImport({
    @cInclude("fcntl.h");
    @cInclude("signal.h");
    @cInclude("sys/file.h");
    @cInclude("sys/wait.h");
    @cInclude("time.h");
    @cInclude("unistd.h");
});

var active_child_pid: c.pid_t = 0;
var shutdown_requested: c_int = 0;

pub const ManagedServer = struct {
    child_pid: ?c.pid_t = null,
    lock: ?StartupLock = null,

    pub fn close(self: *ManagedServer) void {
        if (self.child_pid) |pid| {
            active_child_pid = 0;
            terminateChild(pid);
            self.child_pid = null;
        }
        if (self.lock) |*lock| {
            lock.close();
            self.lock = null;
        }
    }
};

const StartupLock = struct {
    fd: c_int,

    fn close(self: *StartupLock) void {
        _ = c.flock(self.fd, c.LOCK_UN);
        _ = c.close(self.fd);
    }
};

pub fn ensureServer(allocator: std.mem.Allocator, paths: xdg.Paths, cfg: config.Config, allow_remote_server: bool) !ManagedServer {
    installSignalHandlers();
    const endpoint = llama.localEndpoint(allocator, cfg.server_url) catch |err| switch (err) {
        errors.Error.ServerNotLocal => {
            if (allow_remote_server) return .{};
            return errors.Error.ServerNotLocal;
        },
        else => |e| return e,
    };
    defer endpoint.deinit(allocator);

    const startup_deadline = startupDeadline(cfg.server_startup_timeout_sec);
    if (existingServerIsHealthyUntil(allocator, cfg.server_url, cfg.timeout_sec, startup_deadline)) |healthy| {
        if (healthy) return .{};
    } else |err| switch (err) {
        errors.Error.Timeout => return errors.Error.ServerStartupTimeout,
        else => return err,
    }

    if (!endpoint.autostartable) return errors.Error.ServerUserManagedEndpoint;
    if (!cfg.server_autostart) return errors.Error.ServerAutostartDisabled;
    if (!std.mem.eql(u8, cfg.runtime, "llama_server")) return errors.Error.ServerStartFailed;
    if (cfg.model_path.len == 0 or !sys.exists(cfg.model_path)) return errors.Error.ModelMissing;

    const exe = try resolveExecutable(allocator, cfg.llama_server_path);
    defer allocator.free(exe);

    var lock = try acquireStartupLock(allocator, paths, endpoint.lock_key, startup_deadline);
    errdefer lock.close();

    if (existingServerIsHealthyUntil(allocator, cfg.server_url, cfg.timeout_sec, startup_deadline)) |healthy| {
        if (healthy) {
            lock.close();
            return .{};
        }
    } else |err| switch (err) {
        errors.Error.Timeout => return errors.Error.ServerStartupTimeout,
        else => return err,
    }

    if (c.time(null) >= startup_deadline) return errors.Error.ServerStartupTimeout;

    const port_arg = try std.fmt.allocPrint(allocator, "{d}", .{endpoint.port});
    defer allocator.free(port_arg);
    const child_pid = spawnLlamaServer(allocator, exe, cfg.model_path, endpoint.host, port_arg) catch return errors.Error.ServerStartFailed;
    errdefer killChild(child_pid);
    active_child_pid = child_pid;

    try waitUntilHealthy(allocator, cfg.server_url, cfg.timeout_sec, startup_deadline);
    lock.close();
    return .{ .child_pid = child_pid };
}

fn startupDeadline(timeout_sec: u32) c_long {
    return c.time(null) + @as(c_long, @intCast(if (timeout_sec == 0) 1 else timeout_sec));
}

fn remainingStartupSeconds(deadline: c_long) !u32 {
    const remaining = deadline - c.time(null);
    if (remaining <= 0) return errors.Error.ServerStartupTimeout;
    return @intCast(remaining);
}

fn existingServerIsHealthyUntil(allocator: std.mem.Allocator, server_url: []const u8, request_timeout_sec: u32, deadline: c_long) !bool {
    const first_timeout = @min(startupProbeTimeout(request_timeout_sec), remainingStartupSeconds(deadline) catch return errors.Error.ServerStartupTimeout);
    if (llama.healthCheck(allocator, server_url, first_timeout, false)) |_| return true else |err| switch (err) {
        errors.Error.Interrupted => return errors.Error.Interrupted,
        errors.Error.Timeout => {},
        else => return false,
    }
    const second_timeout = @min(request_timeout_sec, remainingStartupSeconds(deadline) catch return errors.Error.ServerStartupTimeout);
    if (llama.healthCheck(allocator, server_url, second_timeout, false)) |_| return true else |err| switch (err) {
        errors.Error.Interrupted => return errors.Error.Interrupted,
        errors.Error.Timeout => return errors.Error.Timeout,
        else => return false,
    }
}

fn killChild(pid: c.pid_t) void {
    if (active_child_pid == pid) active_child_pid = 0;
    terminateChild(pid);
}

fn terminateChild(pid: c.pid_t) void {
    signalChildGroup(pid, c.SIGTERM);
    var status: c_int = 0;
    var attempts: usize = 0;
    while (attempts < 20) : (attempts += 1) {
        const waited = c.waitpid(pid, &status, c.WNOHANG);
        if (waited == pid) return;
        if (waited < 0) {
            if (std.c.errno(-1) == .INTR) continue;
            return;
        }
        _ = c.usleep(100 * 1000);
    }
    signalChildGroup(pid, c.SIGKILL);
    while (true) {
        const waited = c.waitpid(pid, &status, 0);
        if (waited == pid or waited < 0 and std.c.errno(-1) != .INTR) break;
    }
}

fn installSignalHandlers() void {
    _ = c.signal(c.SIGINT, handleSignal);
    _ = c.signal(c.SIGTERM, handleSignal);
}

fn handleSignal(sig: c_int) callconv(.c) void {
    shutdown_requested = sig;
    const pid = active_child_pid;
    if (pid > 0) signalChildGroup(pid, c.SIGTERM);
}

fn signalChildGroup(pid: c.pid_t, sig: c_int) void {
    _ = c.kill(-pid, sig);
    _ = c.kill(pid, sig);
}

fn spawnLlamaServer(allocator: std.mem.Allocator, exe: []const u8, model_path: []const u8, host: []const u8, port: []const u8) !c.pid_t {
    const exe_z = try allocator.dupeZ(u8, exe);
    defer allocator.free(exe_z);
    const model_z = try allocator.dupeZ(u8, model_path);
    defer allocator.free(model_z);
    const host_z = try allocator.dupeZ(u8, host);
    defer allocator.free(host_z);
    const port_z = try allocator.dupeZ(u8, port);
    defer allocator.free(port_z);
    const arg_m = try allocator.dupeZ(u8, "-m");
    defer allocator.free(arg_m);
    const arg_host = try allocator.dupeZ(u8, "--host");
    defer allocator.free(arg_host);
    const arg_port = try allocator.dupeZ(u8, "--port");
    defer allocator.free(arg_port);
    var argv = [_:null]?[*:0]const u8{
        exe_z.ptr,
        arg_m.ptr,
        model_z.ptr,
        arg_host.ptr,
        host_z.ptr,
        arg_port.ptr,
        port_z.ptr,
    };

    const pid = c.fork();
    if (pid < 0) return errors.Error.ServerStartFailed;
    if (pid == 0) {
        _ = c.setpgid(0, 0);
        _ = c.signal(c.SIGINT, c.SIG_DFL);
        _ = c.signal(c.SIGTERM, c.SIG_DFL);
        const devnull = c.open("/dev/null", c.O_RDWR, @as(c_int, 0));
        if (devnull >= 0) {
            _ = c.dup2(devnull, c.STDIN_FILENO);
            _ = c.dup2(devnull, c.STDOUT_FILENO);
            _ = c.dup2(devnull, c.STDERR_FILENO);
            if (devnull > c.STDERR_FILENO) _ = c.close(devnull);
        }
        _ = c.execv(exe_z.ptr, @ptrCast(&argv));
        c._exit(127);
    }
    return pid;
}

pub fn resolveExecutable(allocator: std.mem.Allocator, configured_path: []const u8) ![]const u8 {
    if (configured_path.len == 0) return errors.Error.ServerStartFailed;
    if (std.fs.path.isAbsolute(configured_path) or std.mem.indexOfScalar(u8, configured_path, '/') != null) {
        if (!isExecutable(configured_path)) return errors.Error.ServerStartFailed;
        return allocator.dupe(u8, configured_path);
    }

    const path_owned = sys.getenvOwned(allocator, "PATH") catch null;
    defer if (path_owned) |path| allocator.free(path);
    const path = path_owned orelse "";
    var it = std.mem.splitScalar(u8, path, ':');
    while (it.next()) |dir| {
        if (dir.len == 0) continue;
        const candidate = try std.fs.path.join(allocator, &.{ dir, configured_path });
        if (isExecutable(candidate)) return candidate;
        allocator.free(candidate);
    }
    return errors.Error.ServerStartFailed;
}

fn isExecutable(path: []const u8) bool {
    var path_z = std.heap.page_allocator.allocSentinel(u8, path.len, 0) catch return false;
    defer std.heap.page_allocator.free(path_z);
    @memcpy(path_z[0..path.len], path);
    return c.access(path_z.ptr, c.X_OK) == 0;
}

fn acquireStartupLock(allocator: std.mem.Allocator, paths: xdg.Paths, key: []const u8, deadline: c_long) !StartupLock {
    const lock_dir = try std.fs.path.join(allocator, &.{ paths.state_dir, "runtime" });
    defer allocator.free(lock_dir);
    try sys.makePath(lock_dir);
    const lock_name = try std.fmt.allocPrint(allocator, "{s}.lock", .{key});
    defer allocator.free(lock_name);
    const lock_path = try std.fs.path.join(allocator, &.{ lock_dir, lock_name });
    defer allocator.free(lock_path);

    var path_z = try allocator.allocSentinel(u8, lock_path.len, 0);
    defer allocator.free(path_z);
    @memcpy(path_z[0..lock_path.len], lock_path);
    const fd = c.open(path_z.ptr, c.O_CREAT | c.O_RDWR | c.O_CLOEXEC, @as(c_int, 0o600));
    if (fd < 0) return errors.Error.ServerStartFailed;
    errdefer _ = c.close(fd);

    while (true) {
        if (shutdown_requested != 0) return errors.Error.Interrupted;
        if (c.flock(fd, c.LOCK_EX | c.LOCK_NB) == 0) return .{ .fd = fd };
        const err = std.c.errno(-1);
        if (err == .INTR) continue;
        if (err != .AGAIN) return errors.Error.ServerStartFailed;
        if (c.time(null) >= deadline) return errors.Error.ServerStartupTimeout;
        _ = c.usleep(100 * 1000);
    }
}

fn waitUntilHealthy(allocator: std.mem.Allocator, server_url: []const u8, request_timeout_sec: u32, deadline: c_long) !void {
    while (true) {
        if (shutdown_requested != 0) return errors.Error.Interrupted;
        const probe_timeout = @min(request_timeout_sec, remainingStartupSeconds(deadline) catch return errors.Error.ServerStartupTimeout);
        if (llama.healthCheck(allocator, server_url, probe_timeout, false)) |_| return else |err| switch (err) {
            errors.Error.Interrupted => return errors.Error.Interrupted,
            else => {},
        }
        if (c.time(null) >= deadline) return errors.Error.ServerStartupTimeout;
        _ = c.usleep(100 * 1000);
    }
}

fn startupProbeTimeout(request_timeout_sec: u32) u32 {
    return @max(@as(u32, 1), @min(request_timeout_sec, @as(u32, 2)));
}

test "resolve executable direct path rejects missing file" {
    try std.testing.expectError(errors.Error.ServerStartFailed, resolveExecutable(std.testing.allocator, "/tmp/kotoba-missing-llama-server"));
}
