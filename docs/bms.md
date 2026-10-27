# Supported batteries (BMS)

Le'Casa reads these battery management systems over a Bluetooth connection.
The protocols are a line-by-line Dart port of
[aiobmsble](https://github.com/patman15/aiobmsble) (Apache-2.0, upstream
commit `75f1f1e`, October 2026), and every driver is checked against the
GATT traces of aiobmsble's own test suite (`test/bms/replay_test.dart`).

> **Machine-translated and mostly untested on real batteries.** The Dart
> drivers were machine-translated from aiobmsble's Python code. They pass
> every recorded trace from aiobmsble's test suite, but so far only a
> **Daly** BMS has been tested with Le'Casa on real hardware, and `DL-…`
> Daly modules are read by Le'Casa's own Daly driver rather than the port.
> Every other type on this page should work, but none has been seen
> working on a real battery yet.
>
> If you try Le'Casa with your battery, please
> [open an issue](https://github.com/vdbxio/le-casa/issues/new?title=BMS%20report%3A%20&labels=bms),
> whether it works or not. Useful details:
>
> - battery make and model, and the name it advertises over Bluetooth;
> - the type Le'Casa picked for it (the protocol line on the device page);
> - phone or tablet, and Android or iPadOS version;
> - what read correctly and what looked wrong, compared with the
>   battery's own app (a screenshot of each helps);
> - the raw advertisement from the device page if it was not recognised
>   at all.
>
> Reports that "it just works" are just as welcome: they let us mark a
> type as tested.

A battery is picked up when its advertisement matches one of the patterns
below. Its card shows charge, voltage, current, power, cells, temperatures,
MOSFETs, cycles and alarms where the BMS reports them, polled every 30 s.
Daly modules named `DL-…` keep the older dedicated Daly driver.

## Batteries with a PIN or password

Some BMSs only answer after a PIN. Open the battery's device page in
Le'Casa, type it under **Battery PIN** and tap **Save PIN**. It is stored on
the tablet only and is tried straight away. Leave it empty if you never set
one in the battery's own app.

| Battery | Where the PIN comes from |
| --- | --- |
| ANT smart BMS | Only if a password is set in the ANT BMS app. |
| Dometic Büttner BMS | The PIN set for the battery in the Dometic app. |
| Jiabaida Eleksol BMS | The PIN or password set in the battery app. |
| Jiabaida smart BMS | Only if you set a password in the battery app. JBD and Xiaoxiang apps default to 000000 when one is turned on. |
| Batterieschmiede Saftkiste BMS | The six character password from the Saftkiste app: upper-case letters and digits. |
| 123electric 123\SmartBMS | The four digit PIN set in the 123\SmartBMS app. |

## iPad and iPhone

iOS hides MAC addresses, so the few types recognised only by the start of
their MAC address (Greenway, Wattstunde Nova Core, and some Eleksol and JBD
units without a name) are not picked up on iPad. Everything else matches
the same way on both platforms (`test/bms/matcher_test.dart`).

## All supported types

| Manufacturer | Model | Advertised names | PIN | Module |
| --- | --- | --- | --- | --- |
| Chunguang Song | ABC-BMS | `ABC-*`, `SOK-*`, `NB-*`, `Hoover` |  | `abc_bms` |
| AG Automotive | AG Power Lithium | `AG???L*` |  | `ag_bms` |
| Allpowers | portable power station | `AP R*`, `VOLIX-*` |  | `allpowers_bms` |
| ANT | smart BMS | `ANT?BLE24*`, `ANT?BLE3*` | yes | `ant_bms` |
| ANT | legacy smart BMS | `ANT-BLE[01]*`, `ANT-BLE22*` |  | `ant_leg_bms` |
| Braun Power | smart BMS | `HSKS-*`, `BL-*`, `KS-*`, `Vanvolt-*` |  | `braunpwr_bms` |
| Buknuwo | smart battery | `CDZG*`, `MEY-?????-*` |  | `buknuwo_bms` |
| Generic | C4S100 Smart BMS (RC6621A) | `C4S100IE?????` |  | `c4s_bms` |
| CBT Power | smart BMS | `???[CR]??????` |  | `cbtpwr_bms` |
| Creabest | VB series | `VB?????????` |  | `cbtpwr_vb_bms` |
| Daly | smart BMS | `DL-*` |  | `daly_bms` |
| Daren | smart BMS | `DWF*` |  | `daren_bms` |
| Dometic | Büttner BMS | by service UUID or MAC | yes | `dometic_bms` |
| D-powercore | smart BMS | `DXB-*`, `TBA-*` |  | `dpwrcore_bms` |
| ECO-WORTHY | BW 02/0B | `ECO-WORTHY 02_*`, `DCHOUSE*`, `ECO-WORTHY*` |  | `ecoworthy_bms` |
| EG4 electronics | LL | by service UUID or MAC |  | `eg4_bms` |
| E&J Technology | smart BMS | `L-12V???AH-*`, `LT-12V-*`, `V-12V???Ah-*`, `libatt*`, `SV12V*`, `LT-12???BG-A0[0-6]*`, `LT-24???B-A00[0-2]*`, `G-[0-5][2-8]V[0-9]*A[Hh]-[0-9]*` |  | `ej_bms` |
| Jiabaida | Eleksol BMS | by service UUID or MAC | yes | `eleksol_bms` |
| Felicity Solar | LiFePo4 battery | `F07*`, `F10*` |  | `felicity_bms` |
| Gobel Power | BLE BMS | `BMS-[0-9A-F]*`, `B[0-9][0-9]*` |  | `gobel_bms` |
| Greenway | BMS | by service UUID or MAC |  | `greenway_bms` |
| Humsienk | BMC | `HS*`, `ECO????`, `DCH????` |  | `humsienk_bms` |
| Jiabaida | smart BMS | `@KsM:*`, `JBD-*`, `LSG-*`, `N-?????BL*`, `SJ-???-*`, `SX1*`, `SX60*`, `SBL-*`, `OGR-*`, `TZ-H*`, `12???BL*`, `24???BL*` | yes | `jbd_bms` |
| Jikong | smart BMS | by service UUID or MAC |  | `jikong_bms` |
| Ective | LiPower BMS | by service UUID or MAC |  | `lipower_bms` |
| Lithionics | NeverDie smart BMS | `Li[0-9]-*` |  | `lithionics_bms` |
| Voltagen Power Solutions | MyVolta BLE HW | `VPS-*` |  | `myvolta_bms` |
| Neey | Balancer | `EK-*`, `GW-*` |  | `neey_bms` |
| Offgridtec | LiFePo4 Smart Pro | `SmartBat-[AB]*` |  | `ogt_bms` |
| PeiCheng Technology | PACEEX Smart BMS | `PC-????` |  | `pace_bms` |
| Pro BMS | Smart Shunt | `Pro BMS` |  | `pro_bms` |
| Powerboozt | battery | `BT-Battery*` |  | `pwrboozt_bms` |
| PowerXtreme | smart BMS | by service UUID or MAC |  | `pwrxtreme_bms` |
| Pylontech | RT series | `RT[1-4][2,4,6,8]*` |  | `pylontech_bms` |
| Redodo | Bluetooth battery | `P-12*`, `P-24*`, `PQ-12*`, `PQ-24*`, `R-12*`, `R-24*`, `RO-12*`, `RO-24*`, `T-12*`, `T-24*`, `L-12*`, `L-24*`, `L-51*`, `LT-12???BG-A0[7-9]*`, `LT-24???B-A00[3-9]*`, `LT-24???B-A0[1-9]*`, `LT-24???B-A[1-9]*`, `LT-51*`, `S-*`, `SS-*` |  | `redodo_bms` |
| Renogy | Bluetooth battery | `BT-TH-*` |  | `renogy_bms` |
| Renogy | BT battery pro | `RNGRBP*`, `RNGC*` |  | `renogy_pro_bms` |
| RoyPow | smart BMS | `[BS]12*`, `[BS]24*`, `UT*` |  | `roypow_bms` |
| Batterieschmiede | Saftkiste BMS | by service UUID or MAC | yes | `saftkiste_bms` |
| Saihang Technology | intelligent BMS | `SH*` |  | `saihang_bms` |
| Seplos | smart BMS V3 | `SP??B*`, `XZHX*`, `CSY*`, `SP1??B*`, `ST*` |  | `seplos_bms` |
| Seplos | smart BMS V2 | `BP0?`, `BP1?`, `BP2?` |  | `seplos_v2_bms` |
| Super-B | Epsilon | `Epsilon-*` |  | `superb_bms` |
| Super-B | Epsilon v2 | `Epsilon*` |  | `superb_v2_bms` |
| TDT | smart BMS | `WTDH*`, `WT???AZ*`, `HS*`, `WT???BG*` |  | `tdt_bms` |
| TianPwr | smart BMS | `TP_*` |  | `tianpwr_bms` |
| Topband | smart BMS | by service UUID or MAC |  | `topband_bms` |
| Vatrer | smart BMS | `[2-9]???[0-3]?512??00??` |  | `vatrer_bms` |
| Wattstunde | Nova Core | by service UUID or MAC |  | `ws_nova_bms` |
| 123electric | 123\SmartBMS | `123\SmartBMS` | yes | `x123smart_bms` |

## Updating from upstream

1. `tool/aiobmsble/record.sh` runs aiobmsble's pytest suite with a plugin
   (`bmsrec.py`) that records every GATT read, write and notification into
   `test/bms/vectors/`, and dumps the advertisement samples (`advdump.py`).
2. Port the changed drivers in `lib/bms/drivers/`, keeping them line by line.
3. `python3 tool/aiobmsble/gen_registry.py` rewrites `lib/bms/registry.dart`.
4. `flutter test test/bms/` replays every trace and checks every matcher.
