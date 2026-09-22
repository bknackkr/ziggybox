# <img src="img/ziggybox_ico_64px.png" height="32" alt="ziggybox Logo"> ziggybox
A Zig reimplementation of POSIX shell commands, inspired by Busy/Toybox

## License

This project is licensed under either of:

* Apache License, Version 2.0 ([LICENSE-APACHE](LICENSE-APACHE) or http://www.apache.org/licenses/LICENSE-2.0)
* MIT License ([LICENSE-MIT](LICENSE-MIT) or http://opensource.org/licenses/MIT)

at your option.

### Contribution

Unless you explicitly state otherwise, any contribution intentionally submitted
for inclusion in the work by you, as defined in the Apache-2.0 license, shall be
dual licensed as above, without any additional terms or conditions.

## Building

ziggybox is written in Zig 0.16.0. To build, you need to install it. You can download it from https://ziglang.org/download/ or install it via your system's package manager:

```bash
# Arch Linux
sudo pacman -S zig

# Debian/Ubuntu
sudo apt install zig

# Fedora
sudo dnf install zig
```

### x86-64 and x86 (32-bit)

To compile for 64-bit and 32-bit x86 targets:

```bash
# x86-64 (Linux MUSL)
zig build -Dtarget=x86_64-linux-musl -Doptimize=ReleaseSmall

# x86 (32-bit Linux MUSL)
zig build -Dtarget=x86-linux-musl -Doptimize=ReleaseSmall
```

### AArch64 and ARM (32-bit)

To compile for 64-bit and 32-bit ARM architectures:

```bash
# AArch64 (Linux MUSL)
zig build -Dtarget=aarch64-linux-musl -Doptimize=ReleaseSmall

# AArch32 / ARMv7 (Linux MUSL with hardware float)
zig build -Dtarget=arm-linux-musleabihf -Doptimize=ReleaseSmall
```

## AI transparency statement
I believe it is important for any user of this program to be aware that a non-trivial amount of code in this repository was written by generative AI. It is also important to clarify that code, and only code, was generated this way. All statements, opinions, and images are my own and I am opposed to the use of generative AI for the purposes of image generation and creative/informative writing. Yes, I know I'm a hypocrite. Thank you for reading.
