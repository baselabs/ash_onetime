"""Read the shared hosted-test partition and run one declared comparator lane."""

import json
import os
from pathlib import Path
import subprocess
import sys


def configuration():
    data = json.loads(Path(".github/test-shards.json").read_text())
    data["mutation_shards"] = json.loads(Path(".github/mutation-shards.json").read_text())
    routes = data["matrix_routes"]
    names = [shard["name"] for shard in routes]
    if len(names) != len(set(names)) or any(not shard["values"] for shard in routes):
        raise ValueError("matrix shards must have unique names and nonempty value sets")
    expected = {route for action in ["issue", "rotate", "revoke", "retire", "mint"]
                for route in [action, "external_" + action]}
    if {shard["action"] for shard in routes} != expected:
        raise ValueError("matrix shards must cover every local and external route")
    for action in expected:
        path_count = 18 if action.startswith("external_") else 17
        pairs = [(path, value) for shard in routes if shard["action"] == action
                 for path in shard["path_indices"] for value in shard["values"]]
        wanted = [(path, value) for path in range(path_count)
                  for value in ["va", "vb", "vc", "vd", "ve", "vf"]]
        if sorted(pairs) != sorted(wanted):
            raise ValueError(f"matrix shards must cover each path and value tuple once for {action}")
    groups = [group for shard in data["scheduling_shards"] for group in shard["groups"]]
    if sorted(groups, key=int) != [str(n) for n in range(35)]:
        raise ValueError("each of the 35 scheduling groups must occur once")
    names = [shard["name"] for shard in data["scheduling_shards"]]
    if len(names) != len(set(names)) or any(not shard["groups"] for shard in data["scheduling_shards"]):
        raise ValueError("scheduling shards must have unique names and nonempty groups")
    if data["mutation_shards"] != list(range(1, len(data["mutation_shards"]) + 1)):
        raise ValueError("mutation shards must cover 1 through the shard count")
    return data


def main(arguments):
    data = configuration()
    if arguments == ["--check"]:
        print("Shared test shards cover all routes, scheduling groups and mutation shards once")
        return 0
    if arguments == ["--outputs"]:
        with open(os.environ["GITHUB_OUTPUT"], "a") as output:
            for key, value in data.items():
                if key == "matrix_routes":
                    value = [shard["name"] for shard in value]
                output.write(f"{key}={json.dumps(value, separators=(',', ':'))}\n")
        return 0

    lane, selector = arguments
    directory = "test/ash_onetime/delivery/"
    command = ["mix", "test"]
    if lane == "matrix" and selector in [shard["name"] for shard in data["matrix_routes"]]:
        command += [directory + "comparator_matrix_test.exs", "--only", f"matrix_route:{selector}"]
    elif lane == "scheduling":
        shard = next(shard for shard in data["scheduling_shards"] if shard["name"] == selector)
        command += [directory + "comparator_scheduling_test.exs"]
        for group in shard["groups"]:
            command += ["--only", f"u9_group:{group}"]
    elif lane == "controls" and selector == "":
        # Establish the native transport proofs before any comparator row uses
        # them. Exclude the same group from the following battery so it runs once.
        proof = subprocess.run([
            "mix", "test", directory + "comparator_controls_test.exs",
            "--only", "connection_streams",
        ], check=False)
        if proof.returncode:
            return proof.returncode
        print("::notice title=Native connection prerequisites::"
              "All connection_streams tests passed before the remaining comparator controls.",
              flush=True)
        command += [directory + name for name in [
            "comparator_controls_test.exs", "comparator_matrix_test.exs",
            "comparator_mutations_test.exs", "comparator_positive_controls_test.exs",
            "exit_boundary_controls_test.exs",
        ]]
        command += ["--exclude", "full_matrix", "--exclude", "connection_streams"]
    else:
        raise ValueError("unknown comparator lane or selector")
    return subprocess.run(command, check=False).returncode


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
