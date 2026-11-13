"""Small structural fixture mirroring the upstream plugin anchors used by apply_patch.py.

This is intentionally a minimal test fixture, not a vendored copy of upstream
handles.py. Re-check the patch anchors against the upstream main branch before
running plugin/install-plugin.sh.
"""
import json
import logging
import os
import re
import subprocess


def produce_htcondor_singularity_script(
    containers,
    metadata,
    container_commands,
    input_files,
    probe_scripts=None,
    cleanup_scripts=None,
    init_container_commands=None,
    prestop_trap=None,
    poststart_hooks=None,
):
    try:
        job = f"""
RequestCpus = 1
RequestMemory = 512
Queue 1
"""
        # print(job)
        with open("submit.jdl", "w") as f_:
            f_.write(job)
    except Exception:
        raise
    return "submit.jdl"


def produce_htcondor_host_script(container, metadata):
    return "host.jdl"


def SubmitHandler():
    create_request = json.loads("{}")
    pod = create_request.get("pod", {})
    containers_standalone = create_request.get("container", [])
    metadata = pod.get("metadata", {})
    containers = pod.get("spec", {}).get("containers", [])
    init_containers = pod.get("spec", {}).get("initContainers", [])
    poststart_hooks = {}
    prestop_trap = None
    path = produce_htcondor_singularity_script(
        containers,
        metadata,
        [],
        [],
        probe_scripts=[],
        cleanup_scripts=[],
        init_container_commands=[],
        prestop_trap=prestop_trap,
            poststart_hooks=poststart_hooks,
        )
    return path


class DummyApp:
    def run(self, **kwargs):
        pass


app = DummyApp()
args = type("Args", (), {"port": 4000})()
if __name__ == "__main__":
    app.run(port=args.port, host="0.0.0.0", debug=True)
