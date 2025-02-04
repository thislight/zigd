# Zigd(ev)

Build and manage zig compiler from source tree.

- Automatically set up zig-bootstrap.
- Use ccache if presents.
- Shortcuts to invoke different compilers.

If you just want a usable zig compiler - You may look at [zigup](https://github.com/marler8997/zigup).
Zigd is focus on the zig compiler (& std) development.

## Getting Started

Here assumes you already have a working zigd, named `zigd`.
You also must have git, clang, cmake and ninja on your computer.

To use zigd, you must tell zigd where can found zig compiler source tree,
with environment variable `ZIGD_TREE`.

```sh
export ZIGD_TREE=~/Projects/zig/
```

Use `zigd build` to build the compilers:

```sh
zigd build bootstrap stage1 stage2 stage3
```

This command builds all the stages zigd provides:

- `bootstrap`: [zig-bootstrap](https://github.com/ziglang/zig-bootstrap), which
    provides the key dependencies, like LLVM, with a copy of a new zig compiler.
- `stage1`: The zig compiler from your local source tree, built with CMake/Ninja.
- `stage2`: The zig compiler from your local source tree, with ReleaseFast optimization.
- `stage3`: The zig compiler from your local source tree, with Debug optimization.

The stages here is not the same to the zig compiler's "stage1" "stage2" "stage3".
We use `stageN` here to describe the different build condition.

The `bootstrap` and `stage1` may take hours to complete.

Use `zigd <stage>` to invoke specific compiler:

```sh
zigd stage1 version
zigd stage2 version
zigd stage3 version
```

You can also build specific stage of compiler by changing the argument for `zigd build`:

```sh
zigd build stage3
zigd build stage3 stage2 # Specified order won't affect the build order
```

## LICENSE

This program is free software: you can redistribute it and/or modify it under the terms of the GNU General Public License as published by the Free Software Foundation, either version 3 of the License, or any later version.

This program is distributed in the hope that it will be useful, but WITHOUT ANY WARRANTY; without even the implied warranty of MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE. See the GNU General Public License for more details.

You should have received a copy of the GNU General Public License along with this program. If not, see <https://www.gnu.org/licenses/>.
