use std::{
    env, fs,
    io::{self, Read, Write},
    process::{self, Command},
};

const PACK: &str = "/mnt/wasi1";
const WASI: &str = "/mnt/wasi0";

fn main() {
    if let Err(error) = run() {
        eprintln!("activity-vm-init: {error}");
        let _ = Command::new("/bin/poweroff").args(["-f"]).status();
        process::exit(125);
    }
}

fn run() -> Result<(), String> {
    mount_early()?;
    command("/bin/stty", &["-echo"])?;
    command(
        "/usr/sbin/nft",
        &["-f", "/usr/share/obelisk/activity-vm.nft"],
    )?;

    print!("==========");
    io::stdout().flush().map_err(|error| error.to_string())?;
    wait_for_resume()?;

    fs::create_dir_all(WASI).map_err(|error| error.to_string())?;
    command(
        "/bin/mount",
        &[
            "-t",
            "9p",
            "-o",
            "trans=virtio,version=9p2000.L,msize=8192",
            "wasi0",
            WASI,
        ],
    )?;

    let info = fs::read_to_string(format!("{PACK}/info")).map_err(|error| error.to_string())?;
    let runtime = RuntimeInfo::parse(&info)?;
    for mapping in &runtime.mounts {
        bind_preopen(mapping)?;
    }
    for assignment in runtime.environment {
        let (name, value) = assignment
            .split_once('=')
            .ok_or_else(|| format!("invalid environment assignment: {assignment:?}"))?;
        unsafe { env::set_var(name, value) };
    }

    if runtime.command.is_empty() {
        return Err("pack/info did not contain a command".to_owned());
    }
    Command::new(&runtime.command[0])
        .args(&runtime.command[1..])
        .status()
        .map_err(|error| format!("cannot execute {:?}: {error}", runtime.command[0]))?;
    command("/bin/poweroff", &["-f"])
}

fn mount_early() -> Result<(), String> {
    for path in ["/proc", "/sys", "/dev", "/run", "/tmp", "/etc", PACK] {
        fs::create_dir_all(path).map_err(|error| error.to_string())?;
    }
    command("/bin/mount", &["-t", "proc", "proc", "/proc"])?;
    command("/bin/mount", &["-t", "sysfs", "sysfs", "/sys"])?;
    command("/bin/mount", &["-t", "tmpfs", "tmpfs", "/run"])?;
    command("/bin/mount", &["-t", "tmpfs", "tmpfs", "/tmp"])?;
    command("/bin/mount", &["-t", "tmpfs", "tmpfs", "/etc"])?;
    command("/bin/mount", &["-t", "tmpfs", "tmpfs", "/nix/store"])?;
    fs::write("/etc/resolv.conf", "nameserver 127.0.0.1\n").map_err(|error| error.to_string())?;
    command(
        "/bin/mount",
        &[
            "-t",
            "9p",
            "-o",
            "trans=virtio,version=9p2000.L,msize=8192",
            "wasi1",
            PACK,
        ],
    )
}

fn wait_for_resume() -> Result<(), String> {
    let mut acknowledgement = [0; 2];
    loop {
        io::stdin()
            .read_exact(&mut acknowledgement)
            .map_err(|error| format!("waiting for Wizer resume: {error}"))?;
        if acknowledgement == *b"=\n" {
            return Ok(());
        }
    }
}

fn bind_preopen(mapping: &Mount) -> Result<(), String> {
    if !mapping.guest.starts_with('/') || mapping.guest.contains("/../") {
        return Err(format!("unsafe preopen destination: {:?}", mapping.guest));
    }
    let relative = mapping.guest.trim_start_matches('/');
    let source = format!("{WASI}/{relative}");
    fs::create_dir_all(&mapping.guest).map_err(|error| error.to_string())?;
    command("/bin/mount", &["--bind", &source, &mapping.guest])?;
    if mapping.read_only {
        command("/bin/mount", &["-o", "remount,bind,ro", &mapping.guest])?;
    }
    Ok(())
}

fn command(program: &str, args: &[&str]) -> Result<(), String> {
    let status = Command::new(program)
        .args(args)
        .status()
        .map_err(|error| format!("cannot run {program}: {error}"))?;
    if status.success() {
        Ok(())
    } else {
        Err(format!("{program} exited with {status}"))
    }
}

#[derive(Debug, PartialEq)]
struct Mount {
    guest: String,
    read_only: bool,
}

#[derive(Debug, Default, PartialEq)]
struct RuntimeInfo {
    mounts: Vec<Mount>,
    environment: Vec<String>,
    command: Vec<String>,
}

impl RuntimeInfo {
    fn parse(input: &str) -> Result<Self, String> {
        let mut result = Self::default();
        for record in records(input) {
            let Some((kind, value)) = record.split_once(':') else {
                continue;
            };
            let value = value.trim_start_matches(' ');
            match kind {
                "m" | "mr" if !value.is_empty() => result.mounts.push(Mount {
                    guest: format!("/{}", value.trim_start_matches('/')),
                    read_only: kind == "mr",
                }),
                "env" => result.environment.push(value.to_owned()),
                "c" => result.command = arguments(value)?,
                "e" if result.command.is_empty() => result.command.push(value.to_owned()),
                _ => {}
            }
        }
        Ok(result)
    }
}

fn records(input: &str) -> Vec<String> {
    let mut records = Vec::new();
    let mut current = String::new();
    let mut escaped = false;
    for character in input.chars() {
        if character == '\n' && !escaped {
            records.push(std::mem::take(&mut current));
        } else if character == '\n' {
            current.push('\n');
            escaped = false;
        } else {
            if escaped {
                current.push('\\');
            }
            escaped = character == '\\';
            if !escaped {
                current.push(character);
            }
        }
    }
    if escaped {
        current.push('\\');
    }
    if !current.is_empty() {
        records.push(current);
    }
    records
}

fn arguments(input: &str) -> Result<Vec<String>, String> {
    let mut arguments = Vec::new();
    let mut current = String::new();
    let mut escaped = false;
    for character in input.chars() {
        if escaped {
            if character != ' ' {
                current.push('\\');
            }
            current.push(character);
            escaped = false;
        } else if character == '\\' {
            escaped = true;
        } else if character == ' ' {
            arguments.push(std::mem::take(&mut current));
        } else {
            current.push(character);
        }
    }
    if escaped {
        current.push('\\');
    }
    if !current.is_empty() {
        arguments.push(current);
    }
    Ok(arguments)
}

#[cfg(test)]
mod tests {
    use super::{Mount, RuntimeInfo, arguments};

    #[test]
    fn parses_bochs_runtime_manifest() {
        let parsed = RuntimeInfo::parse(
            "mr: nix/store/abc\nm: obelisk-activity-vm-http\nenv: PATH=/nix/store/abc/bin\nc: /bin/sh /a\\ script x\\ y\n",
        )
        .unwrap();
        assert_eq!(
            parsed,
            RuntimeInfo {
                mounts: vec![
                    Mount {
                        guest: "/nix/store/abc".to_owned(),
                        read_only: true,
                    },
                    Mount {
                        guest: "/obelisk-activity-vm-http".to_owned(),
                        read_only: false,
                    },
                ],
                environment: vec!["PATH=/nix/store/abc/bin".to_owned()],
                command: vec![
                    "/bin/sh".to_owned(),
                    "/a script".to_owned(),
                    "x y".to_owned(),
                ],
            }
        );
    }

    #[test]
    fn preserves_literal_backslashes_in_arguments() {
        let parsed = arguments(r#"bash -c printf\ '%s\n'"#).unwrap();
        assert_eq!(parsed, ["bash", "-c", "printf '%s\\n'"]);
    }
}
