# Fleet Interlude

Fleet's setup experience (the "Setting up your device" screen, the bootstrap package, and ordered software installs) only runs on Macs enrolled through Automated Device Enrollment (ADE). A Mac that enrolls manually, such as a contractor's or employee's own Mac or a host migrating from another MDM, gets none of it. The user lands on the desktop, and software attached to policies arrives whenever those policies happen to run, in no particular order.

Fleet Interlude fills that gap for manually enrolled Macs. It is a script that runs from a policy automation on a newly enrolled host. It opens a swiftDialog window styled like Fleet's native "Setting up your device" page, queues each self-service software title through Fleet's device API in the order you list them, and shows install progress until every step succeeds or fails.

It does not replace Fleet's native setup experience, and it can only install titles marked self-service.

> **NOTE**: This is a community project, not officially supported by Fleet. 
>
> For an example deployment, see [Example deployment](example-deployment.md).

## Why use it

Admins with manual enrollments have asked Fleet for two things that Interlude provides today:

- **A bootstrap step for manual enrollments** ([fleetdm/fleet#46368](https://github.com/fleetdm/fleet/issues/46368)). Interlude runs a defined set of installs before the user starts working, behind a full-screen progress window, the way ADE hosts get with a bootstrap package and setup experience.
- **Control over install order** ([fleetdm/fleet#29921](https://github.com/fleetdm/fleet/issues/29921)). A policy automation runs one script or one software install, never both, and Fleet doesn't let you order policies. Interlude is one script that installs many titles. With `SERIAL_STEPS=true` it waits for each title before queueing the next, so a later step can depend on an earlier one.

It also:

- Works whether or not you deploy Fleet Desktop. orbit writes and rotates the device token either way.
- Works on hosts that only have fleetd, with no Fleet MDM enrollment, for custom packages, Fleet-maintained apps, and script-only packages. App Store (VPP) apps still require the host to be MDM-enrolled in Fleet.
- Gives the end user a progress screen where they would otherwise see nothing.

## When not to use it

- ADE enrollments. Fleet's native setup experience already covers them.
- Titles that aren't self-service. The device API rejects them.
- Windows or Linux hosts. Interlude is macOS only.

## How it works

1. Reads the Fleet server URL from fleetd's managed preferences and the device token from `/opt/orbit/identifier`.
2. Builds the step list from `STEPS` (title names or numeric title IDs), or from every available self-service title if `AUTO_DISCOVER=true`.
3. If swiftDialog isn't on disk (common after a manual MDM enrollment), downloads only Fleet's swiftDialog TUF target into the orbit path. It doesn't reinstall fleetd.
4. Skips titles that are already installed, then queues the rest with `POST /api/latest/fleet/device/{token}/software/install/{title_id}`.
5. Polls `GET /api/latest/fleet/device/{token}/software` and the local filesystem, updating the window until each step finishes or `MAX_WAIT_SECONDS` runs out.
6. Writes `/var/db/fleet-interlude.done` as a sentinel when every step succeeds. If any step fails, the sentinel is not written.

## How soon it starts

Interlude normally runs from a policy with a run-script automation (see the example deployment). Fleet sends a newly enrolled host its policies on the host's first check-in, so a policy that fails until the Interlude sentinel exists fails right away, and Fleet queues the script within minutes of fleetd enrolling. After that, policies run every hour by default (`osquery_policy_update_interval`) and re-run early after an MDM check-in, a manual refetch, or a completed software install. See [Policy automations](https://fleetdm.com/guides/automations#policy-automations).

Once the script starts, it waits up to `WAIT_FOR_CONSOLE_SECONDS` for a user to reach the desktop before opening the window. If nobody logs in, it queues the installs without a window unless `REQUIRE_CONSOLE_USER=true`.



## Security

Fleet Interlude authenticates with the host's device token, the same token Fleet Desktop uses, not a Fleet API token, so the script holds no admin credentials.

- **The token exists without Fleet Desktop.** orbit generates and rotates the token unconditionally at startup, whether or not Fleet Desktop is enabled in your fleetd package. See [`orbit/cmd/orbit/orbit.go`](https://github.com/fleetdm/fleet/blob/main/orbit/cmd/orbit/orbit.go).
- **The token rotates.** orbit generates a random UUID, registers it with Fleet over orbit's own authenticated channel, and writes it to `/opt/orbit/identifier` on the host. orbit replaces it every hour, and Fleet rejects any token older than one hour. The token is never written to the logs. See [Secure Fleet Desktop](https://fleetdm.com/guides/fleet-desktop#secure-fleet-desktop).
- **The token is scoped to one host.** It only authenticates the `/api/latest/fleet/device/{token}/...` routes, and those only act on the host that owns the token: reading that host's software, queueing its self-service installs, and reading its install results. See [Fleet-desktop-token-authenticated routes](https://github.com/fleetdm/fleet/blob/main/docs/Contributing/reference/api-for-contributors.md#fleet-desktop-token-authenticated-routes).
- **Installs are limited to self-service titles.** The install endpoint rejects any title that isn't marked `self_service`. See [Install self-service software by Fleet Desktop token](https://fleetdm.com/docs/rest-api/rest-api#install-self-service-software-by-fleet-desktop-token).

> **Single sign-on (SSO) for Fleet Desktop** (`fleet_desktop.sso_enabled`, Fleet Premium) puts an IdP session in front of the device routes Interlude calls. Requiring end user authentication on the manual enrollment link is a separate setting and is not what this caveat is about. See the [Fleet-desktop-token-authenticated routes reference](https://github.com/fleetdm/fleet/blob/main/docs/Contributing/reference/api-for-contributors.md#fleet-desktop-token-authenticated-routes) for how the session requirement, error responses, and exemptions (including during setup experience) work. Interlude has not yet been fully validated with `fleet_desktop.sso_enabled` turned on.



## Deploy

1. Edit the `CONFIGURATION` block at the top of the script.
2. Upload the script under **Controls > Scripts**, or add it to `controls.scripts` in your GitOps fleet file.
3. Run it manually on a host, or attach it to a policy's run-script automation (`run_script.path` in GitOps).

> For an example production deployment, including the GitOps YAML, see [Example deployment](example-deployment.md).



## Configuration


| Variable                   | Default      | Purpose                                                                            |
| -------------------------- | ------------ | ---------------------------------------------------------------------------------- |
| `STEPS`                    | example list | Titles to install, by name or ID. Use an ID when two titles share a name.          |
| `AUTO_DISCOVER`            | `false`      | If `STEPS` is empty, install every available self-service title.                   |
| `SERIAL_STEPS`             | `true`       | Queue one title at a time, in `STEPS` order.                                       |
| `SERIAL_ON_FAIL`           | `stop`       | In serial mode, `stop` or `skip` after a step fails.                               |
| `DRY_RUN`                  | `false`      | `true` logs what would be queued without installing.                               |
| `DETACH`                   | `true`       | Hand off live runs to a one-shot LaunchDaemon (see Timing).                        |
| `BLUR_SCREEN`              | `true`       | Full-screen kiosk with a blur. `false` shows a resizable window that stays on top. |
| `COLOR_MODE`               | `auto`       | `light`, `dark`, or `auto` (follows the user's macOS appearance).                  |
| `REQUIRE_CONSOLE_USER`     | `false`      | Exit with code 2 if nobody is logged in.                                           |
| `WAIT_FOR_CONSOLE_SECONDS` | `120`        | How long to wait for a user to reach the desktop before opening the window.        |
| `POLL_INTERVAL_SECONDS`    | `8`          | How often to poll Fleet and the filesystem for install progress.                   |
| `MAX_WAIT_SECONDS`         | `3600`       | Overall install timeout.                                                           |
| `HEADER_LOGO_URL`          | Fleet mark   | HTTPS logo above the tracker. Leave empty to hide it.                              |
| `FLEET_URL`                | empty        | Overrides the Fleet server URL the script detects.                                 |


The `WINDOW_TITLE_*` and `WINDOW_MESSAGE_*` variables set the window text.

## Command-line flags

These flags only apply when you run the script by hand, for example `sudo ./fleet-interlude.sh --force --no-blur`.

- `--force`: re-run even if the done marker exists.
- `--debug`: log extra detail for script-package installs.
- `--no-blur`: use a normal window instead of the kiosk.
- `--serial` / `--parallel`: override `SERIAL_STEPS`.
- `--serial-on-fail stop|skip`: override `SERIAL_ON_FAIL`.
- `--color-mode light|dark|auto` (or `--light`, `--dark`, `--auto`): override `COLOR_MODE`.



## Timing

Installing several titles usually takes longer than Fleet's default 300-second script timeout. With `DETACH=true`, live runs copy the script to `/var/db/fleet-interlude/` and continue under the LaunchDaemon `com.fleet.interlude`, so Fleet records the script as successful while installs keep going. 

If you set `DETACH=false`, you may experience timeout errors. You can [raise the default script execution timeout](https://fleetdm.com/docs/configuration/agent-configuration#script-execution-timeout) (`agent_options.script_execution_timeout`) to get around this, just be aware of the consequences of raising your script execution timeout.

## Retries

Fleet's run-script automation fires when a policy first fails on a host. It does not fire again while the policy keeps failing. If Interlude finishes with a failed step, it doesn't write the sentinel, so the policy stays failing but the script won't run again on its own. Fix the title, then run the script on the host from **Host details > Actions > Run script**, or run it by hand with `--force`.

## Logs and exit codes

- The in-process run logs to stdout, which shows under **Host details > Activity** in Fleet.
- The detached worker logs to `/var/log/fleet-interlude.log`.


| Code | Meaning                                                                      |
| ---- | ---------------------------------------------------------------------------- |
| `0`  | Success, including "already completed" and dry runs.                         |
| `1`  | Misconfiguration, not root, missing token, URL, or swiftDialog, or no steps. |
| `2`  | `REQUIRE_CONSOLE_USER=true` and no user is logged in.                        |




## Re-running

To run it again on a host, delete `/var/db/fleet-interlude.done` or pass `--force`.
