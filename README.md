# wedit

[![GitHub version](https://img.shields.io/github/v/tag/ngirard/wedit?label=version&sort=semver&color=blue)](https://github.com/ngirard/wedit/releases)
[![License](https://img.shields.io/github/license/ngirard/wedit?color=green)](LICENSE)
<!-- Add other badges like build status if CI is set up -->
<!-- e.g., [![Build Status](https://img.shields.io/github/actions/workflow/status/ngirard/wedit/YOUR_CI_WORKFLOW.yml?branch=main)](https://github.com/ngirard/wedit/actions) -->

**`wedit` is a smart command-line utility to reliably open files in your preferred editor, ensuring the calling process waits for editing to complete.**

It intelligently honors `$VISUAL` and `$EDITOR`, automatically applies the correct "wait" flags for various editors, provides sane defaults, offers interactive configuration, and gracefully falls back to available alternatives.

## The problem `wedit` solves

Developers often need a consistent way to open files from scripts (e.g., Git hooks, CLI tools) and have the script pause until the editor is closed. Existing solutions can be inconsistent:
* Custom wrappers might only support a few editors.
* System-provided scripts (like `sensible-editor`) might not handle "wait" flags automatically.
* Manually configuring aliases or environment variables (e.g., `EDITOR='code --wait'`) requires per-editor knowledge and setup.

`wedit` aims to be a single, robust, and user-friendly solution for this common task.

## Key features

* **Environment variable aware:** Honors `$VISUAL` and `$EDITOR` environment variables.
* **Automatic wait flags:** Intelligently detects and applies the correct "wait" flags for popular GUI editors (e.g., `code --wait`, `subl --wait`, `gedit --wait`, `kate --block`).
* **Smart fallback hierarchy:**
    1. `$VISUAL`
    2. `$EDITOR`
    3. User configuration (`~/.weditrc`)
    4. System 'editor' alternative (on Linux via `update-alternatives`)
    5. First available editor from a built-in list
    6. Interactive prompt (on first run or if no editor is found)
    7. Fallback to `vi` or `nano` if available.
* **Interactive configuration:** Run `wedit -c` to choose and save your preferred editor from a list of detected ones.
* **Recursion safe:** Prevents accidental infinite loops if `wedit` itself is set as `$EDITOR`.
* **Lightweight & portable:** A single Bash script designed to work on Linux and macOS with minimal dependencies.
* **Editor discovery:** Can list detected editors with `wedit -l`.
* **Flexible control:** Options to force or disable wait behavior (`-w`, `-n`).

## Supported editors

`wedit` has built-in support for detecting and managing wait flags for the following editors:

| Editor      | Detection Command        | Wait Flag(s)           | Notes                                          |
|-------------|--------------------------|------------------------|------------------------------------------------|
| `code`      | `command -v code`        | `--wait`               | VS Code CLI                                    |
| `subl`      | `command -v subl`        | `--wait`               | Sublime Text                                   |
| `atom`      | `command -v atom`        | `--wait`               | Atom                                           |
| `gedit`     | `command -v gedit`       | `--wait`               | GNOME Text Editor                              |
| `kate`      | `command -v kate`        | `--block`              | KDE Advanced Text Editor                       |
| `gvim`      | `command -v gvim`        | `--remote-wait-silent` | GUI Vim                                        |
| `vim`, `nvim`| `command -v vim`         | *none* (TTY blocks)    | Terminal editors block by default              |
| `nano`      | `command -v nano`        | *none*               | Terminal editor                                |
| `emacsclient`| `command -v emacsclient` | `--no-wait`            | Blocks when file is saved via server-edit hook |
| `vi`        | `command -v vi`          | *none* (TTY blocks)    | Common fallback terminal editor                |

*Terminal-based editors (like Vim, Nano, Vi) naturally block the calling process, so no explicit wait flags are needed for them unless overridden.*

## Installation

### 1. From releases (recommended)

You can download the `wedit` script or pre-built packages (if available) from the [GitHub Releases page](https://github.com/ngirard/wedit/releases).

* **Script:** Download `wedit.sh`, make it executable, and place it in your `$PATH`.
    ```bash
    VERSION="v0.1.0" # Replace with the latest version
    curl -Lo wedit https://github.com/ngirard/wedit/releases/download/${VERSION}/wedit.sh
    chmod +x wedit
    sudo mv wedit /usr/local/bin/wedit
    ```

* **Packages (.deb, .rpm):**
    If `.deb` or `.rpm` packages are provided, download the appropriate file and install using your system's package manager. For example, for a `.deb` file:
    ```bash
    # Example for .deb package
    # sudo dpkg -i wedit_${VERSION}_amd64.deb
    # sudo apt-get install -f # To install dependencies if any
    ```
    (The `nfpm.yaml` suggests packages might be generated, installing to `/usr/local/bin/wedit`.)

### 2. Manual installation (from source)

Clone the repository or download `src/wedit.sh`:
```bash
git clone https://github.com/ngirard/wedit.git
cd wedit
sudo cp src/wedit.sh /usr/local/bin/wedit
sudo chmod +x /usr/local/bin/wedit
```

## Usage

```
wedit [options] [--] <file> [<file>...]
wedit [options]
```

**Common operations:**

* **Edit a file:**
    ```bash
    wedit myfile.txt
    wedit notes.md config.yaml
    ```

* **Configure your preferred editor:**
    `wedit` will guide you through selecting an editor from those it detects on your system. The choice is saved to `~/.weditrc`.
    ```bash
    wedit -c
    ```
    After selection, `wedit` will open `~/.weditrc` with the newly chosen editor.

* **List detected editors:**
    ```bash
    wedit -l
    ```

* **Get help:**
    ```bash
    wedit -h
    wedit --help
    ```

**Options:**

* `-h, --help`: Show the help message and exit.
* `-c, --config`: Configure the preferred editor interactively. Saves to `~/.weditrc` and then opens this file.
* `-l, --list`: List all detected known editors and their properties.
* `-n, --no-wait`: Override default wait behavior; do not add wait flags for GUI editors.
* `-w, --wait`: Force waiting behavior. This is default for GUI editors with wait flags and all TTY editors. Primarily ensures GUI wait flags are used.
* `--`: Signals the end of options; all subsequent arguments are treated as file names.

**Example use case (Git commit hook):**
Set `wedit` as your Git editor to ensure Git waits for your message:
```bash
git config --global core.editor "wedit"
```

## Configuration

`wedit` determines which editor to use based on the following hierarchy:

1. **`$VISUAL` environment variable:** If set, its value is used.
2. **`$EDITOR` environment variable:** If `$VISUAL` is not set and `$EDITOR` is, its value is used.
3. **User configuration file:**
    * `~/.weditrc` (Primary)
    * `~/.selected_editor` (Fallback for reading, compatible with Debian's `select-editor`)
    The file should contain a line like: `SELECTED_EDITOR="your-editor-command --optional-args"`
    You can create/manage this file using `wedit -c`.
4. **System 'editor' alternative:** On Linux systems using `update-alternatives`, `wedit` will try to use the system-configured `editor`.
5. **Built-in list of known editors:** `wedit` scans for known editors in your `$PATH` (see [Supported Editors](#supported-editors)).
6. **Interactive prompt:** If no editor is found through the above methods and no configuration exists, `wedit` will prompt you to select an editor. This choice is then saved to `~/.weditrc` for future use.
7. **Final fallback:** If all else fails, `wedit` will attempt to use `vi` or `nano` if they are available.
8. **Error:** If no editor can be found, `wedit` will exit with an error.

## Development

This project uses `just` (a command runner) for common development tasks. See the `justfile`.

**Prerequisites:**
* Bash
* `shellcheck` (for linting `src/wedit.sh`)
* `just` (optional, but recommended for using `justfile` commands)

**Common `just` commands:**
* `just lint`: Check the script with `shellcheck`.
* `just test`: Run all tests (requires test suite to be set up in `./tests/`).
* `just test-one <name>`: Run a specific test file `./tests/test_<name>.sh`.
* `just release`: (For maintainers) Executes the release script.

## Contributing

Contributions are welcome! Whether it's bug reports, feature suggestions, or pull requests:

1. **Issues:** Please check for existing issues before opening a new one. Provide as much detail as possible.
2. **Pull Requests:**
    * Fork the repository.
    * Create a new branch for your feature or bug fix.
    * Make your changes. Ensure `shellcheck` passes (`just lint`).
    * Add tests if applicable.
    * Commit your changes with clear messages.
    * Push to your fork and submit a pull request.

## License

This project is licensed under the **MIT License**. See the [LICENSE](LICENSE) file for details.

---

Copyright (c) 2025, Nicolas Girard
