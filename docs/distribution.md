# Distribution and local installation

Kogen is distributed from this repository as an escript. Build and install the current Git revision with:

```sh
make install-local
```

The command builds with the versions pinned in `mise.toml` and installs an immutable generation at `~/.kogen/gen/<git-sha>/`. `~/.local/bin/kogen` is a symlink to that generation's `kogen` launcher. The launcher calls the absolute `escript` from the build toolchain and passes its adjacent `kogen.escript` archive, so a project's `.tool-versions` or mise-activated `PATH` cannot start Kogen on a different OTP. The generation check compares the archive header and ZIP members, and checks that the launcher still names the expected build runtime and archive.

Kogen does not add its runtime to `PATH` for project commands. Those commands keep using the PATH from the project's mise environment; Kogen's runtime markers are removed from child environments.

`KOGEN_INSTALL_HOME` defaults to `$HOME` and can point `make install-local` at a temporary home for isolated installation checks. The local install regression test uses this option, then starts the symlinked launcher from a temporary project with an alternate Erlang installation when available, or a failing `escript` stub at the front of `PATH` otherwise.
