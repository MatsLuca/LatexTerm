#!/bin/sh
# mark NAME [LOG] — stage direction into the state log (default $DEMO_LOG)
printf '{"t": %s, "mark": "%s"}\n' "$(python3 -c 'import time;print(int(time.time()*1000))')" "$1" >> "${2:-$DEMO_LOG}"
