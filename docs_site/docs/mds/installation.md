
Add *tofu* to build.zig.zon:
```bach
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
