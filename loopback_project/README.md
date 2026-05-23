# eth_loopback_test — DE2-115 Ethernet validation project

## What this project does
Receives raw Ethernet frames from your laptop, extracts the first payload
byte (byte 14 of the Ethernet frame), and displays it on the 7-segment
display. This validates that the full physical path works:

  laptop NIC → Ethernet cable → DE2-115 PHY → eth_mac_bridge → HEX display

## Files
```
eth_loopback_test.qpf   Quartus project file
eth_loopback_test.qsf   Pin assignments (from authoritative DE2-115 QSF)
eth_loopback_test.sdc   Timing constraints
rtl/
  eth_loopback_test.v   Top-level RTL (this is what you're testing)
  eth_mac_bridge.v      MII receive bridge (PHY → byte stream)
```

## Step 1 — Open in Quartus
File → Open Project → select eth_loopback_test.qpf

Confirm:
- Assignments → Device: EP4CE115F29C7 (Cyclone IV E)
- Assignments → Settings → Top-level entity: eth_loopback_test

## Step 2 — Compile
Processing → Start Compilation (full compile, ~5 minutes)
Should complete with 0 errors. Timing warnings on the CDC paths are OK.

## Step 3 — Program the board
Tools → Programmer → USB-Blaster → select output_files/eth_loopback_test.sof
Click Start. Should show 100% and "Successful".

## Step 4 — Verify the board is alive
LEDR[17] should blink at 1Hz immediately after programming.
If it doesn't blink, press KEY[0] to release reset.

## Step 5 — Connect the cable
Plug an Ethernet cable from your laptop's ASIX USB adapter directly into
the DE2-115's top Ethernet jack (ENET0 — closer to the board edge).

## Step 6 — Send a test frame
```
python3 send_test_byte.py --iface "\Device\NPF_{0A78C0FE-1936-4708-8BEC-96B2F0BE0A7D}" --value 0xAB
```

## Step 7 — Read the board
- HEX5:HEX4  shows "--"  (confirms this design is loaded)
- HEX3:HEX2  increments  (frame counter)
- HEX1:HEX0  should show "AB"

## Debug KEY buttons (if HEX1:HEX0 doesn't show AB)
The design captures bytes at four adjacent positions simultaneously.
Hold a KEY to switch what's displayed:

| KEYs held    | Displays              | Expected for our test frame |
|--------------|-----------------------|-----------------------------|
| None         | byte at position 15   | AB (payload byte)           |
| KEY[1] only  | byte at position 13   | 12 (EtherType high byte)    |
| KEY[2] only  | byte at position 16   | 00 (padding)                |
| KEY[1]+KEY[2]| byte at position 14   | 34 (EtherType low byte)     |

If none of these match, hold KEY[1]+KEY[2] and verify HEX shows "34".
That confirms the frame is arriving and byte counting is working.
Then report what each KEY position shows — the correct one will have AB.

## Background traffic note
The frame counter (HEX3:HEX2) will increment even before you run the
Python script — your OS automatically sends ARP/mDNS frames when a cable
is plugged in. This is expected and means the bridge is working.

LEDR[16] lights for 0.5s after any frame arrives (sticky indicator).
