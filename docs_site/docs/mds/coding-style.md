# Coding style

## Big-endian imports vs Little-endian imports

There are two "parties" in Zig about where imports should be placed.

**Big-endian** - imports are placed at the top of the file, before the code.

**Little-endian** - imports are placed at the bottom of the file, after the code.

I belong to the LE party. At least, tofu sources use LE imports.

But in examples, I am using BE just for your convenience.

## Type inference

Type inference is convenient **for the developer**:

- when working with comptime-generated code
- when the IDE displays the actual types

It is **not** convenient **for the reader**:

- when looking at small examples or snippets
- when reading code in a browser or editor without type hints

That’s why in examples — and increasingly in my own projects — I try to avoid type inference.

## Automatic dereference for the `.` operator on single pointers

I am slowly moving toward always dereference explicitly.

