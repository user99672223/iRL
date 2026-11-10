#!/usr/bin/env bash
# Drive Rocket League through several offline arenas (free play) to stream in their shaders.
# Starts on the Exhibition Match screen (Play > Play Offline > Exhibition; set team size/bots once). Coordinates are in
# rl-ui.sh screenshot space (960 wide), measured on Season 24 UI.
# Usage: tour.sh ARENAS SHOTDIR
set -u
U="$(dirname "$0")/rl-ui.sh"; N="${1:-5}"; SD="${2:-/tmp}"
drive() { for r in 1 2 3; do $U key 5; $U hold w 3 & $U mouse 1 2; wait; $U mouse 3 0.2; $U key 4; $U hold d 1.5; $U hold w 3; $U key 1; $U hold a 2; $U key BackSpace; done; }
for i in $(seq 1 "$N"); do
  $U click 270 406; sleep 35                       # CREATE MATCH (Exhibition, random arena, bots) -> load
  $U click 170 159; sleep 8                        # CHOOSE TEAM -> JOIN BLUE (else it spectates forever)
  $U shot "$SD/arena-$i-in.png"
  drive; $U key Return; drive                      # play; Return skips kickoff/replay prompts
  $U key Escape; sleep 2; $U click 478 338; sleep 2    # pause -> EXIT TO MAIN MENU -> dialog
  $U click 425 326; sleep 15                       # YES -> main menu
  $U click 60 243; sleep 5                         # PLAY
  $U click 478 345; sleep 5                        # PLAY OFFLINE
  $U click 365 283; sleep 5                        # EXHIBITION (settings persist)
done
