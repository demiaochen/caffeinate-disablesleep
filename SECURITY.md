# Security

## Short version

Awake sessions do not need a password or make a permanent system change. They
use the same macOS power assertions as `caffeinate -disu`. macOS releases them
as soon as the app stops running.

**Stay awake with lid closed** is different. It changes a protected system
setting called `disablesleep`, so macOS asks for an administrator password.

On an administrator account, the first prompt also installs a small permission
file. This lets the app turn that one setting on and off without asking again.
It does not grant access to your files, a root shell, or any other command. You
can remove it at any time in the app's settings, or install it there before you
first use the lid setting.

The permission belongs to your account, not to the app. Any app or script
running under your account can use it to turn that setting on or off.
Preventing sleep can drain the battery and make a closed Mac hot.

## What gets installed

If you are signed in to an administrator account, the first password prompt
does two things. It turns on `disablesleep` and writes this file:

`/etc/sudoers.d/caffeinate-disablesleep`

It is owned by `root:wheel`, has mode `440`, and contains:

```text
<your short name> ALL=(root) NOPASSWD: /usr/bin/pmset -a disablesleep 0, /usr/bin/pmset -a disablesleep 1
```

The first `ALL` means the rule applies on any host. `(root)` means the commands
run as root. Neither field permits every command. Only the two commands after
`NOPASSWD` are allowed.

Both commands turn `disablesleep` off and on. Neither accepts a file path, a
user name, or a shell command. Reading the current power settings needs no
permission, so `pmset -g` is not in the rule.

The **Lid permission** switch in settings installs the same file on its own,
without turning `disablesleep` on. Switching it off deletes the file and turns
the setting off in one step.

The app also runs `sudo -n -l` to check whether the rule is active. This lists
the permissions for your account without opening a password prompt.

Before putting the file in place, the app:

- checks it with `visudo -cf`
- sets its owner to `root:wheel`
- sets its mode to `440`
- moves it into place only after every check succeeds

The app only installs the rule for an administrator account with a short name
matching `^[A-Za-z0-9_.-]+$`. A standard account can still use the lid setting
when an administrator enters their password, but it will ask every time.

Code: [`Sources/LidLock.swift`](Sources/LidLock.swift).

## What it grants

Sudo authorizes your account. It does not check which app asked to run the
command. While the rule is installed, any program running as you can run those
two `pmset` commands without a password.

`/usr/bin/pmset` is protected by System Integrity Protection, so another
program cannot replace it. The rule does not allow arbitrary root commands. It
only allows turning `disablesleep` on and off.

Once written, the rule stays in place even if the account later loses
administrator access. It remains until you delete the file.

While a `NOPASSWD` rule is installed, `sudo -l` may also list the commands your
account can run as root without asking for a password.

## Installing and removing it

The simplest way is in the app. Open settings from the version number in the
panel, or press ⌘, and switch **Lid permission** off. That turns `disablesleep`
off and deletes the permission file in one step, after asking for your
password. The same switch installs it again.

If you would rather do it yourself, always turn off `disablesleep` before
deleting the permission file.

You can turn off **Stay awake with lid closed** in the app, then remove the
file:

```sh
sudo rm /etc/sudoers.d/caffeinate-disablesleep
```

You can also do both steps in Terminal:

```sh
sudo pmset -a disablesleep 0
sudo rm /etc/sudoers.d/caffeinate-disablesleep
```

For a Homebrew uninstall, reset the setting first:

```sh
sudo pmset -a disablesleep 0
brew uninstall --zap --cask demiaochen/tap/caffeinate-disablesleep
```

This order matters. Once the permission file is gone, the app cannot silently
reset the setting.

## What happens when the app stops

`disablesleep` is a saved system setting. It stays on until something turns it
off. The app tries to turn it off during a normal quit, but it cannot do that
after a crash or forced stop.

| Event | The flag |
| --- | --- |
| Turn off the lid setting | Turns off immediately. |
| Turn off **Lid permission** in settings | Turns off, and the permission file is deleted. |
| Quit or press ⌘Q | Turns off silently when the permission file is installed. Without it, the setting stays on. |
| Crash, `kill`, or `kill -9` | Stays on. The next launch reads the real setting and shows it in the panel. |
| Log out or restart | Normally turns off because macOS asks the running app to quit first. If the app is not running, the setting can remain on. |
| Change it in Terminal | The panel follows the new value while it is open. |
| Delete the app while it is on | Stays on. Turn it off before uninstalling. |

Check the current value with:

```sh
pmset -g | grep SleepDisabled
```

Awake sessions are simpler. macOS releases their power assertions as soon as
the app stops running.

## Why the app does not install a helper

A privileged helper is a second small program that ships inside an app and is
installed as a background service running as root. The app never runs root
commands itself. It sends a request to the helper, and the helper checks the
signature of whoever asked, so only that one signed app can use it. The
permission then belongs to the app rather than to your account.

That is stricter, and it is the right answer for software that needs root
often. The cost is a root service living on the Mac for as long as the app is
installed, with its own startup job, update path, and uninstall cleanup. Any
bug in it is a bug running as root.

This app changes one on or off setting. A small sudoers rule is easier to
inspect, lists only two commands, and can be deleted in one line.
