# Factorio Zarf package

Packages Factorio `2.1.24` as `2.1.24-build.3`, matching the chart's current
application version. Use compatible clients and saves. Saves from newer game
versions generally cannot be loaded by older servers.

Requires current Zarf and Maru, an initialized Zarf cluster, and (for imports)
Kubernetes image-volume support, generally available in Kubernetes 1.35.
The namespace must permit root init containers to prepare PVC ownership.

## Synchronize mods from a save

Set `factorio.mods.syncFromSave: true` to read the selected save's mod list
with Factorio's `--sync-mods` command before starting the server. This works
with an imported save or one already on the PVC. No `mods.portal` list is
needed; the manual mod downloader is bypassed in this mode.

Copy `deploy-values.example.yaml` to `deploy-values.local.yaml` if you have not
already done so. Keep all deployment settings in that single local file. The
example enables `factorio.mods.syncFromSave` and keeps
`factorio.factorioServer.update_mods_on_start` false. It expects an imported save
or a save already on the PVC; it disables new-save generation.

For Mod Portal downloads, either set `factorio.account.accountSecret` to an
existing Secret in the `factorio` namespace containing `username` and `token`
keys, or leave it empty and set `factorio.account.username` and
`factorio.account.token` in your local file so the chart creates the Secret.
Use the Mod Portal token, not your account password. The example includes all
these fields. Deploy using only your local values file:

```sh
zarf package deploy build/zarf-package-factorio-amd64-2.1.24-build.3.tar.zst \
  --values deploy-values.local.yaml \
  --set-variables SAVE_PATH=/absolute/path/to/saves --confirm
```

With `load_latest_save: true` (the default), synchronization selects the newest
complete save ZIP by modification time, including autosaves, and records that
selection in a shared temporary volume. Startup loads that exact save, even if
another file becomes newer afterward. Incomplete `*.tmp.zip` files are ignored.
Set `load_latest_save: false` to select `factorio.factorioServer.save_name`
instead, using the filename without `.zip`. A save must already exist, and
`update_mods_on_start` must remain false. Sync runs
on each pod creation. Downloaded mods persist in `/factorio/mods`; account
credentials are stored only in a temporary directory in the sync container,
removed when synchronization exits. The server still has its normal account
Secret mount when configured.

Mod Portal downloads require outbound access and valid credentials. Mods not
available on the portal must be installed separately. This uses Factorio's own
sync behavior; it does not promise preservation of historical mod versions.
Review mod compatibility before upgrading an existing save from 2.0 to 2.1.
Keep a backup before allowing the upgraded server to save it.

## Build

Run `maru run build` from this directory. The package downloads chart version
`1.4.0` from `oci://ghcr.io/jbmay/helm-charts/factorio` and embeds it alongside
the Factorio image. No sibling chart checkout is required. Artifacts go in
ignored `build/`; remove them with `maru run clean`. No saves are included at
build time.

## Deploy

```sh
cp deploy-values.example.yaml deploy-values.local.yaml
zarf package deploy build/zarf-package-factorio-amd64-2.1.24-build.3.tar.zst \
  --values deploy-values.local.yaml --confirm
```

For import, place `.zip` saves directly inside a local directory. Do not unzip
them. The default `load_latest_save: true` resumes the newest complete save,
including autosaves. To choose a particular imported save, set
`factorio.factorioServer.load_latest_save: false` and set
`factorio.factorioServer.save_name` to its filename without `.zip`. Deploy with:

```sh
zarf package deploy build/zarf-package-factorio-amd64-2.1.24-build.3.tar.zst \
  --values deploy-values.local.yaml \
  --set-variables SAVE_PATH=/absolute/path/to/saves --confirm
```

No OCI image reference or enable flag needs to be entered in your values file.
`SAVE_PATH` causes the before-deploy actions to build and push the image, set
the top-level `saveImport.enabled: true` and `saveImport.image` to its registry
reference, and map those values onto the chart's `saveImport` settings. These
generated values are applied for this deployment; your local values file is not
rewritten. An empty or omitted `SAVE_PATH` disables import automatically.
`factorio.saveImport.overwrite` is the import setting you can configure in your
values file; the example shows it explicitly.

Zarf's embedded tools create an OCI image, push it through Zarf's authenticated
registry tunnel, and mount it read-only for import. Docker is not required.
Temporary local OCI files are removed afterward. Save data stays in the local
directory, the cluster registry, and the PVC; it need not be published publicly.

Multiple ZIP saves are supported and retain their filenames in `/factorio/saves`.
Existing files are preserved. Set `factorio.saveImport.overwrite: true` to
replace matching files once per image and overwrite setting. An import marker
prevents repeating the copy on pod restarts. Unrelated saves are never deleted.

`generate_new_save: true` creates the selected save if absent and skips
generation when it exists. `load_latest_save: false` selects the named save;
set it to true to resume the latest save, including autosaves. Change the name
and redeploy to switch saves. Omit `SAVE_PATH` when saves are already on the
PVC. Save the active game before restarting it.

Values beneath `factorio` pass through to the chart, including server settings,
persistence, resources, mods, passwords, and service configuration. Image
references, pull secrets, and security contexts are fixed in `helm-values.yaml`.
Top-level `saveImport.enabled` and `saveImport.image` are set by the deploy
action; use `SAVE_PATH` to control them. Mods require network access and any
necessary credentials. Keep secrets in ignored `deploy-values.local.yaml` or
reference existing Kubernetes Secrets.

The example exposes UDP NodePort `31497`; connect to a node address on that
port. Allow UDP traffic through any node or external firewall.
The listener explicitly binds to `0.0.0.0:31497` to match that NodePort.
`factorio.factorioServer.bindAddress` overrides the bind IP, and
`factorio.factorioServer.port` overrides the game port. By default the game
port follows `service.port` for NodePort services and is 34197 for other types.

```sh
kubectl -n factorio get deployment,pod,pvc,service
kubectl -n factorio logs deployment/factorio -c factorio
# Only when save import is enabled:
kubectl -n factorio logs deployment/factorio -c import-save-image
```

## Public server list and outbound NAT

A public listing is discovery, not a relay: players still connect directly to
the server's advertised UDP endpoint. Factorio uses its ping-pong servers to
discover that public IP and port. If the CNI or another NAT device rewrites
outbound source ports differently for each destination, the discovered port
can differ from the reachable NodePort. In that situation, connecting through
the public server list will fail even though direct connection to the node IP
and NodePort works. Successful registration does not prove the advertised
endpoint is reachable.

We reproduced this with Flannel v0.27.4's default masquerading behavior on
Talos: Factorio listened on UDP port 31497 and the NodePort was also 31497, but
the ping-pong servers reported different random external ports. Logs contained
`Received own address message reply with conflicting address` and
`Determining own address has failed. Best guess`. Explicitly binding the
listener to the NodePort did not resolve it.

Disabling Flannel's fully random masquerading with
`--ip-masq-fully-random-disable` resolved this deployment's public-list
connectivity. After applying it and restarting Factorio, the ping-pong servers
consistently confirmed the node's public IP with port 31497, and joining through
the public server list worked.

For Talos-managed Flannel, persist the argument in a machine-config patch:

```yaml
cluster:
  network:
    cni:
      name: flannel
      flannel:
        extraArgs:
          - --ip-masq-fully-random-disable
```

Preserve any existing Flannel extra arguments. This is a cluster networking
setting, not a Factorio Helm value; neither this chart nor the Zarf package
applies it automatically. Ensure the running Flannel DaemonSet receives the
argument and its active masquerade rules no longer contain `--random-fully`.
In our existing Talos cluster, the live DaemonSet also needed updating after
the machine-config patch. Save the game and restart Factorio afterward to test
fresh address discovery; existing NAT mappings can retain old ports.

Disabling full randomization lets NAT preserve source ports where possible,
but collisions or another NAT layer can still change them. This affects all
Flannel-managed masqueraded traffic, not just Factorio. Other CNIs may have
different settings; verify that the advertised IP and port match the externally
reachable endpoint.

References: [Flannel v0.27.4 masquerade rules](https://github.com/flannel-io/flannel/blob/v0.27.4/pkg/trafficmngr/iptables/iptables.go),
[Talos Flannel configuration](https://docs.siderolabs.com/talos/v1.12/reference/configuration/v1alpha1/config).

Increment `build.N` in `zarf.yaml` when releasing changes to the package.
