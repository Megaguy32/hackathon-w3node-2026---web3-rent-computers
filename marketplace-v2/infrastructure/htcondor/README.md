# HTCondor configuration

These files configure a small, controlled demo pool. `CLAIMTOBE` is not real authentication: it accepts a client-claimed identity. The `ALLOW_* = *` entries are acceptable only when the pool port is restricted by a firewall to the known demo machines. Never use this configuration on a publicly reachable pool.

## Marketplace / pool host

1. Install HTCondor using the official package repository for your Linux distribution.
2. Substitute your public DNS name into `01-pool.conf.template` and install it as `/etc/condor/config.d/01-pool.conf`.
3. Install `00-auth-demo.conf` as `/etc/condor/config.d/00-auth-demo.conf`.
4. Ensure TCP/9618 is reachable only from the provider's public egress IP (and any explicitly required admin address). Do not open it to `0.0.0.0/0`.
5. Restart and inspect the daemons:

```bash
sudo systemctl restart condor
condor_status -af Machine Name State
```

## Provider host

1. Install HTCondor and Apptainer natively on the host or VM (do not nest Apptainer in Docker for this demo).
2. Substitute the pool hostname into `01-provider.conf.template` and install it as `/etc/condor/config.d/01-provider.conf`.
3. Install the same `00-auth-demo.conf` as a demo-only configuration (tighten access as needed for the environment).
4. Restart HTCondor:

```bash
sudo systemctl restart condor
condor_status -af Machine Name Name State HasSingularity
```

The provider is expected to initiate outbound communication to the pool. CCB is intended for providers behind NAT; it does not mean every possible firewall topology is automatically supported. Validate connectivity on the actual network.

## Firewall reminder

The pool host's port 9618 is the public collector/shared-port entry point. Restrict it to known source addresses. A mobile carrier network may use changing or carrier-grade NAT egress addresses, which makes static IP allowlisting unreliable.

Do not assume `HasSingularity` is populated on every HTCondor build. Verify the actual ClassAd on the provider and adjust the listing UI if your configuration uses a different Apptainer capability signal.
