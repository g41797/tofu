
Add *tofu* to build.zig.zon:
```bash
zig fetch --save git+https://github.com/g41797/tofu
```

Add *tofu* to build.zig:

```zig title="Add dependency"
    const tofu: *build.Dependency = b.dependency("tofu", .{
        .target = target,
        .optimize = optimize,
    });
```

```zig title="For any xyz_mod module that uses tofu, add the following code"     
    xyz_mod.addImport("tofu", tofu.module("tofu"));
```
```zig title="Import tofu"
pub const tofu = @import("tofu");
```

---

## Network Backend Selection

Tofu supports two network backends, selected at compile time:

```bash
zig build                        # stdposix backend (default)
zig build -Dnetwork=posixnet     # posixnet backend (vendored usockets)
```

- **`stdposix`**: Uses Zig's standard library and native POSIX/Windows syscalls.
- **`posixnet`**: Uses the high-performance vendored usockets C wrapper. Recommended for targets where native Zig socket support is evolving.
