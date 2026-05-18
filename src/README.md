# Step 1: MAC Loopback Test (path B, foundation)

This step proves alexforencich's `eth_mac_mii_fifo` works on your DE2-115. No
IP, no UDP, no XDP — just send an Ethernet frame and verify byte 14 lands on
the HEX displays.

When this step works, you can be confident the MAC is rock solid and we'll
build IP/UDP on top of it in Step 2 onwards.

## Project layout

```
your_project_directory/
├── eth_loopback_v2_top.v        ← top-level wrapper (this folder)
├── eth_loopback_v2_top.qsf      ← Quartus settings (this folder)
├── eth_loopback_v2_top.sdc      ← timing constraints (this folder)
├── send_test_byte.py            ← reuse from previous step
└── verilog-ethernet/            ← clone of alexforencich's repo
    ├── rtl/
    │   ├── eth_mac_mii_fifo.v
    │   └── ... (10 other files referenced in QSF)
    └── lib/axis/rtl/
        ├── axis_async_fifo.v
        └── axis_async_fifo_adapter.v
```

## Build steps

### 1. Clone the repo (one-time)

```bash
cd your_project_directory
git clone https://github.com/alexforencich/verilog-ethernet.git
```

After cloning, verify these files exist:

```bash
ls verilog-ethernet/rtl/eth_mac_mii_fifo.v
ls verilog-ethernet/lib/axis/rtl/axis_async_fifo.v
```

If `lib/axis` is empty (it's a submodule), initialize it:

```bash
cd verilog-ethernet
git submodule update --init --recursive
cd ..
```

### 2. Open in Quartus

1. Launch Quartus Prime Lite
2. File → New Project Wizard
3. Working directory: your project folder
4. Top-level entity: `eth_loopback_v2_top`
5. Family: Cyclone IV E, device EP4CE115F29C7
6. Skip adding files when prompted (the QSF handles them)
7. After project is created: **File → Open → eth_loopback_v2_top.qsf**, and
   verify it loaded the file list and pin assignments

Alternatively, just copy the QSF/SDC/V files into a folder, then from the
command line:

```bash
quartus_sh --flow compile eth_loopback_v2_top
```

### 3. Compile

Processing → Start Compilation.

Expected output:
- 0 errors
- Some warnings from the verilog-ethernet modules about "intermediate value
  assigned but never used" — these are safe to ignore
- **Possible warning** about MII_TX_CLK input timing — check it's not an error
- Resource usage: ~3000-4000 LEs, ~5-10 M9K blocks for the FIFO

If you get errors:

- "Can't resolve module eth_mac_mii_fifo": your `verilog-ethernet/` clone is
  in the wrong place. Check the paths in the QSF.
- "Pin X has multiple location assignments": one of the pin assignments
  conflicts. Check against your DE2-115 manual.
- "Unsupported feature: BUFR": the `CLOCK_INPUT_STYLE("BUFR")` parameter on
  the MAC is Xilinx-specific. Change to `"BUFG"` in the instantiation.

### 4. Program the board

1. Power on the DE2-115
2. Connect USB-Blaster
3. Plug Ethernet cable: DE2-115's ENET0 (left RJ45) → your USB-Ethernet adapter
4. Tools → Programmer
5. Add File → `output_files/eth_loopback_v2_top.sof`
6. Start

After programming you should see:
- `LEDR[17]` blinks at ~1 Hz (heartbeat)
- All HEX displays show `FF FF FF FF FF FF` (initial values — frame_count=0,
  bad_frame=0, test_byte=FF default)
- The green link LED on the RJ-45 jack lights up if the cable is good

### 5. Send a test frame

On Windows, with Npcap installed and running as Administrator:

```powershell
python send_test_byte.py --list
```

Find your USB-Ethernet adapter, then:

```powershell
python send_test_byte.py --iface "Ethernet 5" --value 0x42
```

(Substitute your actual adapter name.)

## What to look for

After sending the frame:

| LEDR | Meaning | Expected |
|---|---|---|
| LEDR[17] | Heartbeat | Steady 1 Hz blink |
| LEDR[16] | ENET0_RX_DV direct | Flickers during the send |
| LEDR[15] | AXI rx_axis_tvalid | Flickers during the send |
| LEDR[14] | rx_fifo_good_frame | Brief pulse per frame (lit but blink-fast) |
| LEDR[13] | rx_fifo_bad_frame | Should stay dark (FCS OK) |
| LEDR[12] | rx_fifo_overflow | Should stay dark |
| LEDR[11] | rx_error_bad_frame | Should stay dark |
| LEDR[10] | rx_error_bad_fcs | Should stay dark |

| HEX | Meaning | Expected after `--value 0x42` |
|---|---|---|
| HEX1:HEX0 | Last frame's byte 14 | `42` |
| HEX3:HEX2 | Good frame count | `01` (or whatever count after multiple sends) |
| HEX5:HEX4 | Bad frame count | `00` |

## Try variations

```powershell
# Different value
python send_test_byte.py --iface "Ethernet 5" --value 0xAB

# Many frames
python send_test_byte.py --iface "Ethernet 5" --value 0xCD --count 100 --gap 0.01
```

After the second command HEX1:HEX0 should show `CD` and HEX3:HEX2 should
count to `64` (100 in hex).

## Failure modes & debug

- **No heartbeat blink**: bitstream didn't program. Re-program. If still
  nothing, check that the SOF file actually built (`output_files/*.sof`).
- **Heartbeat blinks but LEDR[16] stays dark when sending**: PHY isn't getting
  signal. Check cable, check that the link LED on the RJ-45 is lit, try
  another cable.
- **LEDR[16] flickers but HEX displays don't change**: MAC isn't accepting
  the frames. Most likely cause: pin assignment wrong (check ENET0_RXD
  pins against DE2-115 manual). Less likely: FCS failures — check LEDR[13]
  and LEDR[10].
- **HEX shows wrong byte value (consistent offset like 'C2' instead of '42')**:
  pin assignment swapped for RXD bits. Check ENET0_RXD[3:0] pin order.
- **Good frames count is increasing but bad frames also increase**: PHY is
  receiving but the FCS check is failing. Could be wire noise (try shorter
  cable) or wrong PHY config (some PHY modes don't auto-negotiate cleanly).
  This still proves the path mostly works — proceed to Step 2.
- **Frame count exactly matches what you sent**: you're done. Move to Step 2.

## What's next

When step 1 works:

- **Step 2**: ARP responder. We'll make the FPGA respond to ARP "who has
  192.168.1.42" with its own MAC address, so the laptop's network stack can
  send IP/UDP packets to us. This is what enables actual IP routing.

Tell me when step 1 passes (or fails) and I'll write step 2.
