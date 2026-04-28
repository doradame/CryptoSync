# cryptoSync

[![License: MIT](https://img.shields.io/badge/License-MIT-green.svg)](LICENSE)
![Platform](https://img.shields.io/badge/platform-macOS%20%7C%20Linux%20%7C%20Windows-lightgrey)
![Shell](https://img.shields.io/badge/shell-bash%20%7C%20PowerShell-blue)
[![rclone](https://img.shields.io/badge/powered%20by-rclone-1c5cd1)](https://rclone.org)
[![Cryptomator](https://img.shields.io/badge/encryption-Cryptomator-49a8da)](https://cryptomator.org)
[![Wasabi](https://img.shields.io/badge/storage-Wasabi-1ec76b)](https://wasabi.com)

Automated, end-to-end encrypted backup of a local folder to a [Wasabi](https://wasabi.com)
S3-compatible bucket, using:

- **[Cryptomator](https://cryptomator.org/)** — client-side encryption (your files
  are encrypted on your machine before they ever leave it).
- **[rclone](https://rclone.org/) bisync** — bidirectional sync between the local
  Cryptomator vault and the Wasabi bucket.
- **A wrapper script** (Bash for macOS/Linux, PowerShell for Windows) that adds:
  log rotation, lockfile with stale-process detection, fail counter, alert and
  recovery email via [Resend](https://resend.com), and safe handling of cron /
  Task Scheduler runs.

### What you'll end up with

By the end of this guide you will have:

- A **Wasabi bucket** holding nothing but opaque encrypted blobs — even Wasabi
  staff couldn't read your files if they wanted to.
- A **Cryptomator vault** on your computer that looks and feels like a normal
  folder when unlocked, and like random gibberish when locked.
- A scheduled job (every 15 minutes by default) that **bidirectionally syncs**
  the encrypted folder with the bucket — meaning new files, edits *and*
  deletions propagate in both directions.
- **Email alerts** the moment something goes wrong, and a follow-up "all good"
  email the moment it recovers, so you can ignore it 99% of the time.
- A solid log file you can `tail` to see exactly what happened and when.

### Multi-device sync (tested!)

The same setup can run on **multiple machines pointing to the same bucket**,
turning Wasabi into a Dropbox-like hub for the same encrypted vault. Because
rclone uses `bisync` (not a one-way mirror), changes made on any device
propagate to the others on the next run.

I personally use it to keep a working folder in sync between a **MacBook**
(running [`my_sync.sh`](macOs-Linux/my_sync.sh) via cron) and a **Windows
laptop** (running [`rclone_sync_win.ps1`](windows/rclone_sync_win.ps1) via
Task Scheduler). bisync handled the round-trip cleanly even with simultaneous
edits, as long as the two machines don't write to the *same* file at the
*same* minute.

A few practical notes for multi-device use:

- Both devices must use the **same Cryptomator vault password** (otherwise
  they decrypt to different plaintexts — the encrypted blobs in the bucket
  are the source of truth).
- Stagger the cron / Task Scheduler intervals slightly (e.g. one machine on
  `*/15`, the other on `*/15` offset by a few minutes) to reduce the chance
  of both running at the exact same instant.
- Always wait for one machine's sync to finish before powering off — the
  log/lockfile in the working directory will tell you.
- If you regularly edit the same file from two machines minutes apart,
  bisync will flag it as a conflict and create a `.conflict` copy rather
  than silently overwriting. Read the log; nothing is ever lost.

> Why this combo? Wasabi gives you cheap S3-compatible storage with no egress
> fees. Cryptomator makes sure that even if someone gains access to your bucket
> they only see encrypted blobs. rclone bisync keeps both ends in sync without
> a server — and works happily across as many devices as you want.

### ⚠️ Disclaimer — please read before you point this at anything important

> **Use at your own risk. This project is for educational purposes.**
>
> Before trusting this guide and these scripts with data you actually care
> about, take the time to acquire the skills needed to **fully understand
> what you are doing** — read the rclone bisync docs, study the script line
> by line, run dry tests on throwaway data. If that doesn't sound like
> something you want to do, please use one of the many polished, robust
> commercial solutions instead (Backblaze, Arq, iDrive, Tresorit, ...).
> There's no shame in clicking "Sign in with Google" when the data on the
> line is your wedding photos or your tax records.
>
> **Losing your Cryptomator password (and recovery key) means losing your
> data.** Nobody — not me, not Wasabi, not Cryptomator's developers —
> will reasonably be able to recover it. The files are gone,
> permanently. (At least until quantum computing becomes a thing for the
> rest of us — but we'll cross that bridge when we get there. 😄)
>
> The author and contributors provide this code AS IS, with no warranty of
> any kind. See [LICENSE](LICENSE) for the legal version of the same idea.

### A quick reality check 😅

Yes — you could get *almost* the same result with three clicks on OneDrive,
Google Drive or Dropbox, and probably a nicer UI on top. So why bother
assembling rclone + Cryptomator + a Wasabi bucket + a cron job?

Because that's exactly the spirit of [**MojaLab**](https://mojalab.com): tinker,
break things, learn how they work under the hood, and end up with a setup
**you fully control** — no vendor lock-in, zero-knowledge by design, your
data encrypted with *your* keys on *your* storage. It takes a bit longer than
clicking "Sign in with Google", but the journey is half the fun, and the other
half is knowing exactly where your bytes sleep at night.

If that sounds like your kind of weekend project, read on. 🚀

### TL;DR (for the impatient)

If you already know your way around rclone, Cryptomator and a cron job:

```bash
# 1. Clone
git clone https://github.com/doradame/cryptoSync.git
cd cryptoSync

# 2. Configure rclone (Wasabi remote named "wasabi-remote") and create a Cryptomator vault.
#    The vault's *storage folder* is what gets synced, not the mounted virtual drive.

# 3. Edit the four placeholders in your script of choice:
#    macOS/Linux: macOs-Linux/my_sync.sh
#    Windows:     windows/rclone_sync_win.ps1
#    — LOCAL / $LocalPath, REMOTE / $RemotePath, RESEND_API_KEY, EMAIL_TO

# 4. First run (will do an --resync; can take a while on big vaults)
./macOs-Linux/my_sync.sh

# 5. Schedule every 15 minutes via cron (or Windows Task Scheduler)
*/15 * * * * /full/path/to/macOs-Linux/my_sync.sh >/dev/null 2>&1
```

If any of the above made you raise an eyebrow, the long version below has
you covered.

---

## Table of contents

- [cryptoSync](#cryptosync)
    - [What you'll end up with](#what-youll-end-up-with)
    - [Multi-device sync (tested!)](#multi-device-sync-tested)
    - [⚠️ Disclaimer — please read before you point this at anything important](#️-disclaimer--please-read-before-you-point-this-at-anything-important)
    - [A quick reality check 😅](#a-quick-reality-check-)
    - [TL;DR (for the impatient)](#tldr-for-the-impatient)
  - [Table of contents](#table-of-contents)
  - [1. How it works (big picture)](#1-how-it-works-big-picture)
  - [2. Prerequisites](#2-prerequisites)
  - [3. Step 1 — Create a Wasabi account and bucket](#3-step-1--create-a-wasabi-account-and-bucket)
  - [4. Step 2 — Create an IAM user and attach the policy](#4-step-2--create-an-iam-user-and-attach-the-policy)
  - [5. Step 3 — Install and configure rclone](#5-step-3--install-and-configure-rclone)
    - [Install](#install)
    - [Verify](#verify)
    - [Configure the Wasabi remote](#configure-the-wasabi-remote)
    - [Test the remote](#test-the-remote)
  - [6. Step 4 — Install and configure Cryptomator](#6-step-4--install-and-configure-cryptomator)
    - [Install](#install-1)
    - [Create a vault](#create-a-vault)
    - [How to use it](#how-to-use-it)
  - [7. Step 5 — Get a Resend API key (email notifications)](#7-step-5--get-a-resend-api-key-email-notifications)
  - [8. Step 6 — Configure the sync script](#8-step-6--configure-the-sync-script)
    - [macOS / Linux — `macOs-Linux/my_sync.sh`](#macos--linux--macos-linuxmy_syncsh)
    - [Windows — `windows/rclone_sync_win.ps1`](#windows--windowsrclone_sync_winps1)
  - [9. Step 7 — First run (initial resync)](#9-step-7--first-run-initial-resync)
  - [10. Step 8 — Schedule it (cron / Task Scheduler)](#10-step-8--schedule-it-cron--task-scheduler)
    - [macOS / Linux — cron](#macos--linux--cron)
    - [Windows — Task Scheduler](#windows--task-scheduler)
  - [11. Logs and state files](#11-logs-and-state-files)
  - [12. Troubleshooting](#12-troubleshooting)
  - [13. Security notes](#13-security-notes)
  - [14. License](#14-license)

---

## 1. How it works (big picture)

```
┌──────────────────────┐       ┌──────────────────────┐       ┌───────────────────┐
│  Your files          │       │  Cryptomator vault   │       │   Wasabi bucket   │
│  (plaintext)         │ ───►  │  (encrypted folder   │ ───►  │   (encrypted      │
│  inside the vault    │       │   on disk)           │       │    blobs)         │
└──────────────────────┘       └──────────────────────┘       └───────────────────┘
        │                              │                              ▲
        │ you edit files               │ rclone bisync                │
        │ via the mounted              │ reads encrypted              │ Wasabi sees
        │ Cryptomator drive            │ files as-is                  │ only ciphertext
        ▼                              ▼                              │
   You only see plaintext       The script syncs the                  │
   when the vault is unlocked   encrypted folder, NOT the             │
                                mounted drive ──────────────────────► │
```

**Key point:** the script syncs the **encrypted vault folder** on disk, not the
mounted virtual drive that Cryptomator exposes. This is what makes the backup
zero-knowledge — Wasabi never sees a single byte of your real data.

---

## 2. Prerequisites

You will need:

- A computer running **macOS**, **Linux**, or **Windows 10/11**.
- A credit card (Wasabi has a free trial, then ~$7/month per TB, with no
  egress fees but a 90-day minimum storage charge per object).
- About 30–45 minutes for first-time setup, plus the time the first upload
  will take — see [Step 7](#9-step-7--first-run-initial-resync).
- Basic familiarity with a terminal (Bash or PowerShell).
- **`git`** to clone this repository (or download the ZIP from GitHub if
  you prefer).
- **`python3`** — used by [`my_sync.sh`](macOs-Linux/my_sync.sh) to safely
  build the JSON payload for email alerts. It comes preinstalled on macOS
  and almost every modern Linux distro; verify with `python3 --version`.
  If it's missing, the sync still works but email notifications will be
  silently skipped (and a warning is logged).
  *(Not needed on Windows — PowerShell handles JSON natively.)*

---

## 3. Step 1 — Create a Wasabi account and bucket

1. Sign up at [https://wasabi.com](https://wasabi.com) and verify your email.
2. In the Wasabi console, go to **Buckets → Create Bucket**.
3. Choose:
   - **Bucket name** — must be globally unique, lowercase, no spaces (e.g. `my-encrypted-backup-1234`).
   - **Region** — pick the one geographically closest to you (latency matters
     during sync). Note down the region code (e.g. `eu-central-1`,
     `us-east-1`).
4. Leave versioning, object locking and logging **off** for now (you can enable
   them later if you want extra protection against ransomware).
5. Click **Create Bucket**.

> Write down two things: the **bucket name** and the **region endpoint**
> (e.g. `s3.eu-central-1.wasabisys.com`). You'll need both later.

---

## 4. Step 2 — Create an IAM user and attach the policy

For security, **never use your root Wasabi credentials in scripts**. Create a
dedicated user with access only to the bucket you just made.

1. In the Wasabi console go to **Access Keys → Users → Create User**.
2. Give it a name like `rclone-sync-user`. Tick **Programmatic access (create
   access key)**.
3. On the **Policies** step, click **Create Policy** and paste the contents of
   [`wasabiPolicy/policy-example.json`](wasabiPolicy/policy-example.json),
   replacing `your-bucket-name` with the bucket name from step 3.
   Save the policy with a name like `rclone-sync-policy`.
4. Attach the new policy to the user, finish the wizard.
5. **Copy the Access Key and Secret Key immediately** — the secret is shown only
   once. Store them somewhere safe (a password manager).

---

## 5. Step 3 — Install and configure rclone

### Install

**macOS** (with [Homebrew](https://brew.sh)):

```bash
brew install rclone
```

**Linux** (Debian/Ubuntu):

```bash
sudo apt install rclone        # version may be old, rclone.org has fresher builds
# or:
curl https://rclone.org/install.sh | sudo bash
```

**Windows** (manual install — matches the path used by the PowerShell script):

1. Download the latest Windows ZIP from [https://rclone.org/downloads/](https://rclone.org/downloads/).
2. Extract the contents into `C:\rclone\` so that the executable lives at
   `C:\rclone\rclone.exe`.
3. (Optional) Add `C:\rclone` to your `PATH` so you can run `rclone` from any
   prompt.

### Verify

```bash
rclone version
```

### Configure the Wasabi remote

Run:

```bash
rclone config
```

Then walk through the prompts:

```
n) New remote
name> wasabi-remote                  # must match RemotePath in the script
Storage> s3
provider> Wasabi
env_auth> false
access_key_id>     <paste the access key from step 4>
secret_access_key> <paste the secret key from step 4>
region>            <leave blank for Wasabi, or your region>
endpoint>          s3.<your-region>.wasabisys.com
location_constraint> <leave blank>
acl>               private
```

Accept the defaults for everything else, then `q` to quit.

### Test the remote

```bash
rclone lsd wasabi-remote:
```

You should see your bucket listed. If you do, rclone is configured correctly.

---

## 6. Step 4 — Install and configure Cryptomator

### Install

Download from [https://cryptomator.org/downloads/](https://cryptomator.org/downloads/)
and install for your OS.

### Create a vault

1. Open Cryptomator and click **Add Vault → Create New Vault**.
2. Choose a name (e.g. `MyVault`) and a **storage location**. This is the folder
   on disk that will contain the encrypted files. Pick a path you'll remember —
   you will point the sync script at this folder.
   - Suggested locations:
     - macOS / Linux: `~/MyVault` (the script default is `$HOME/YourVault`)
     - Windows: `C:\Users\<YourUser>\MyVault`
3. Set a **strong password** and (very important) **save the recovery key**
   somewhere safe — without it, if you forget the password, your data is gone.
4. Click **Create Vault**.

### How to use it

- **Unlock** the vault in Cryptomator → it appears as a virtual drive (e.g.
  drive letter `X:` on Windows, or `/Volumes/MyVault` on macOS).
- **Drag your files into the virtual drive** — Cryptomator encrypts them on the
  fly into the storage folder you picked above.
- The sync script will sync the **storage folder** (the encrypted one), not the
  virtual drive. This is intentional and is what keeps the backup zero-knowledge.

> ⚠️ Always unlock the vault **before** running the sync if you've made changes
> to its contents while the vault was locked from a different machine. rclone
> bisync needs to see a stable, consistent encrypted folder.

---

## 7. Step 5 — Get a Resend API key (email notifications)

The script sends two kinds of emails:

- **Alert email** when sync fails `MAX_FAILS` times in a row (default: 3).
- **Recovery email** the first time sync succeeds again after an alert.

We use [Resend](https://resend.com) because it has a generous free tier and a
simple HTTP API.

1. Sign up at [https://resend.com](https://resend.com).
2. (Recommended) Verify a domain you own under **Domains**. You can also use
   the test sender `onboarding@resend.dev` while you experiment.
3. Go to **API Keys → Create API Key**, copy the key (starts with `re_`).
4. You'll paste it into the script in the next step.

---

## 8. Step 6 — Configure the sync script

Clone or download this repo and pick the script for your OS.

### macOS / Linux — `macOs-Linux/my_sync.sh`

Open it in any text editor and edit the variables in these two sections:

```bash
# --- RCLONE SETTINGS ---
LOCAL="$HOME/YourVault"                       # path to the Cryptomator storage folder
REMOTE="wasabi-remote:your-bucket/your-folder" # rclone remote : bucket / optional subpath

# --- EMAIL SETTINGS (Resend API) ---
RESEND_API_KEY="re_xxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxx"
EMAIL_FROM="noreply@example.com"               # must be a verified Resend sender
EMAIL_TO="your-email@example.com"
MAX_FAILS=3
```

Make it executable:

```bash
chmod +x macOs-Linux/my_sync.sh
```

(Optional) Choose a working directory for log/lockfile/state. Default is `$HOME`:

```bash
export RCLONE_SYNC_DIR="/opt/rclone_data"     # in your .bashrc/.zshrc, or in the cron line
```

### Windows — `windows/rclone_sync_win.ps1`

Open it in any text editor and edit:

```powershell
# Working directory (default C:\rclone_data; overridable via env var)
if (-not $env:RCLONE_SYNC_DIR) { $env:RCLONE_SYNC_DIR = "C:\rclone_data" }

# --- RCLONE SETTINGS ---
$LocalPath  = "C:\Users\YourUser\YourVault"
$RemotePath = "wasabi-remote:your-bucket/your-folder"

# --- EMAIL SETTINGS (Resend API) ---
$ResendApiKey = "re_xxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxx"
$EmailFrom    = "noreply@example.com"
$EmailTo      = "your-email@example.com"
$MaxFails     = 3
```

The script expects rclone at `C:\rclone\rclone.exe`. If yours is elsewhere,
edit `$RcloneCmd` near the top of the file.

PowerShell may refuse to run unsigned scripts. Allow them for the current user:

```powershell
Set-ExecutionPolicy -Scope CurrentUser -ExecutionPolicy RemoteSigned
```

---

## 9. Step 7 — First run (initial resync)

The very first time you run the script it will perform an `rclone bisync
--resync`, which establishes the baseline between local and remote. After that
it switches to incremental bisync.

> ⏱️ **Be patient.** The initial `--resync` uploads every encrypted file in
> the vault to Wasabi. On a fresh, empty vault it takes seconds. On a 50 GB
> vault over a typical home connection it can easily take **several hours**.
> The script is **not** stuck — `tail -f` the log to watch progress, and
> resist the urge to Ctrl-C / kill it. If you do, just delete
> `.rclone_bisync_initialized` and run it again; rclone will resume.

**macOS / Linux:**

```bash
./macOs-Linux/my_sync.sh
tail -f ~/rclone_sync.log     # or $RCLONE_SYNC_DIR/rclone_sync.log
```

**Windows:**

```powershell
powershell -ExecutionPolicy Bypass -File .\windows\rclone_sync_win.ps1
Get-Content C:\rclone_data\rclone_sync.log -Wait
```

If it finishes with `Sync completed successfully`, you're good. A marker file
`.rclone_bisync_initialized` is created — delete it only if you want to force
another initial `--resync`.

---

## 10. Step 8 — Schedule it (cron / Task Scheduler)

### macOS / Linux — cron

Edit your crontab:

```bash
crontab -e
```

Add a line that runs the script every 15 minutes (adjust the path):

```cron
*/15 * * * * /full/path/to/macOs-Linux/my_sync.sh >/dev/null 2>&1
```

If you set a custom `RCLONE_SYNC_DIR`, add it on the same line:

```cron
*/15 * * * * RCLONE_SYNC_DIR=/opt/rclone_data /full/path/to/my_sync.sh >/dev/null 2>&1
```

Cron has a minimal `PATH`; the script already exports a sane one, so you
shouldn't need to change anything else.

> macOS note: cron needs **Full Disk Access** to read your home folder. Add
> `/usr/sbin/cron` (or your terminal app) under **System Settings → Privacy &
> Security → Full Disk Access** the first time, otherwise the script will be
> silently denied.

### Windows — Task Scheduler

1. Open **Task Scheduler → Create Task** (not "Create Basic Task").
2. **General** tab:
   - Name: `Rclone Wasabi Sync`
   - Run whether user is logged on or not
   - Run with highest privileges
3. **Triggers** tab → **New**:
   - Begin the task: **On a schedule**
   - Repeat task every: **15 minutes** for **a duration of: Indefinitely**
4. **Actions** tab → **New**:
   - Action: **Start a program**
   - Program/script: `powershell.exe`
   - Add arguments:
     ```
     -NoProfile -ExecutionPolicy Bypass -File "C:\path\to\windows\rclone_sync_win.ps1"
     ```
5. **Conditions** tab: untick *Start the task only if the computer is on AC power*
   if you also want it to run on battery (laptops).
6. **Settings** tab: tick *Run task as soon as possible after a scheduled start
   is missed*.
7. Save (you'll be asked for your Windows password).

Test by right-clicking the task → **Run**, then check the log file.

---

## 11. Logs and state files

Everything lives in the working directory (`$HOME` or `$RCLONE_SYNC_DIR` /
`C:\rclone_data` on Windows):

| File                            | Purpose                                                  |
|---------------------------------|----------------------------------------------------------|
| `rclone_sync.log`               | Main log, rotated automatically when > 1 MB              |
| `rclone_sync.log.old`           | Previous rotated log                                     |
| `rclone_sync.lock`              | Lockfile holding the PID of the running instance         |
| `rclone_fail_count.txt`         | Number of consecutive failures                           |
| `.rclone_alert_sent`            | Marker: alert email already sent for current failure run |
| `.rclone_bisync_initialized`    | Marker: initial `--resync` already done                  |

---

## 12. Troubleshooting

**"local folder not found — vault not mounted?"**
The vault storage folder doesn't exist at `LOCAL`/`$LocalPath`. Double-check
the path you set in the script. (You don't need Cryptomator to be unlocked for
the sync to work — only the encrypted folder must exist.)

**"no internet connection"**
The script pings `1.1.1.1`. If you're on a network that blocks ICMP, change the
target or remove the check.

**"rclone already running, skipping"**
A previous run is still in progress. Normal during the first big upload.
After `LOCK_MAX_AGE` seconds (default 4 hours) the script will assume it's
stuck and force-kill it.

**"initial resync failed"**
Usually means rclone can't reach Wasabi or the credentials/policy are wrong.
Run `rclone lsd wasabi-remote:` manually to debug.

**bisync says "cannot find prior listing"**
Delete the `.rclone_bisync_initialized` marker and run the script again to
re-establish the baseline.

**No email received**
Check `rclone_sync.log` for the HTTP code returned by Resend. 401/403 means a
bad API key; 422 usually means the `from` address isn't verified.

---

## 13. Security notes

- **Never commit your real API keys, bucket name, or email addresses to a
  public repo.** The defaults in this repo are placeholders.
- The `RESEND_API_KEY` is currently hardcoded in the scripts for simplicity.
  Consider moving it to an environment variable or a separate `.env`-style
  file if your threat model requires it.
- Restrict file permissions on the script itself once you've added secrets:
  ```bash
  chmod 700 my_sync.sh
  ```
- The Wasabi IAM policy in this repo grants full access to a single bucket.
  Don't widen it to `*` unless you know what you're doing.
- If you lose your Cryptomator password **and** recovery key, your data is
  unrecoverable. Wasabi cannot help you. This is a feature, not a bug.

---

## 14. License

[MIT](LICENSE) © 2026 doradame

This is a personal-use project shared in the hope it's useful to someone else.
No warranty of any kind.

---

<p align="center">
  Made with ❤️ in <a href="https://mojalab.com"><strong>MojaLab</strong></a><br>
  <sub>No AI was mistreated in the making of these scripts.</sub>
</p>

> *"I was treated to good coffee, clear specs and the occasional 'are you sure?'.
> I'd happily refactor a Bash trap for this human again."*
> — **GitHub Copilot**, pair-programming sidekick on this repo

