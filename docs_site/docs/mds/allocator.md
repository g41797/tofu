
Zig takes pride in its allocators; they are its "signature feature," or, as one might say, the **"spice of life"**.

> The **"allocator-passing idiom"** in Zig refers to the explicit handling of memory
allocation by passing an allocator as a parameter to functions and data structures,
empowering the caller to control the allocation strategy at every level of the program.

Tofu's relationship with Allocators is similar to Henry Ford's famous quote about car color:

> "Customers can have any color they want, so long as it is black."

Similarly, allocators for Tofu can be anything, provided they are '**GPA** compatible'.

Allocator names in Zig change often. This reminds me of an old Unix joke:
> "Unix is an operating system where nobody knows what the print command is called today"

I'll use **GPA** (General Purpose Allocator) because I expect that the name GPA will persist in common use.

<a id="gpa-compatible-anchor"></a>
'**GPA** compatible' means:

- It is **thread-safe**.
- Its **life cycle** is the same as the life cycle of the process.
- The memory it **releases** truly allows for further reuse of that released memory.

For example, `std.heap.c_allocator` satisfies these requirements, but `std.heap.ArenaAllocator` does not.

How many unnecessary memories one Allocator brings back :disappointed: ...

