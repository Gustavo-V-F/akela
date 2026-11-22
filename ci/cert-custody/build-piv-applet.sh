#!/usr/bin/env bash
# Builds the PIV applet and the jCardSim simulator that emulate an A3 smart card on Windows,
# at pinned commits, the way OpenSC's CI does. Needs Java 8, Maven and Ant. Usage: build-piv-applet.sh OUT
set -euo pipefail
out=$(mkdir -p "$1" && cd "$1" && pwd)
src=$(mktemp -d)
cd "$src"
fetch() { # REPO COMMIT DIR
    git init -q "$3" && git -C "$3" fetch -q --depth 1 "https://github.com/$1.git" "$2" && git -C "$3" checkout -q FETCH_HEAD
}
fetch martinpaljak/oracle_javacard_sdks 700ec80afdda210a0e62fb6a151a9cddc1acd244 sdks
fetch Jakuje/jcardsim 7053179eb0719f1d273f5702c435d6512969a4eb jcardsim
fetch arekinath/PivApplet 5cb14a9e8d16e92fbad73dcad86a219a9210554f PivApplet
git -C PivApplet submodule update -q --init --depth 1
(cd jcardsim && JC_CLASSIC_HOME=$src/sdks/jc305u3_kit mvn -q initialize && JC_CLASSIC_HOME=$src/sdks/jc305u3_kit mvn -q -DskipTests clean install)
(cd PivApplet && JC_HOME=$src/sdks/jc305u3_kit ant -q dist)
cp jcardsim/target/jcardsim-3.0.5-SNAPSHOT.jar "$out/jcardsim.jar"
cp -r PivApplet/bin "$out/piv-applet"
cp PivApplet/test/jcardsim.cfg "$out/"
