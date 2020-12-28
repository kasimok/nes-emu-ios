//
//  Mapper_MMC5.swift
//  nes-emu-ios
//
//  Created by Tom Salvo on 7/1/20.
//  Copyright © 2020 Tom Salvo.
//
//  Permission is hereby granted, free of charge, to any person obtaining a copy
//  of this software and associated documentation files (the "Software"), to deal
//  in the Software without restriction, including without limitation the rights
//  to use, copy, modify, merge, publish, distribute, sublicense, and/or sell
//  copies of the Software, and to permit persons to whom the Software is
//  furnished to do so, subject to the following conditions:
//
//  The above copyright notice and this permission notice shall be included in all
//  copies or substantial portions of the Software.
//
//  THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
//  IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
//  FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE
//  AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
//  LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM,
//  OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN THE
//  SOFTWARE.

import Foundation
import os

/// Some comments on MMC5 functionality and registers are copied from https://wiki.nesdev.com/w/index.php/MMC5

struct Mapper_MMC5: MapperProtocol
{
    enum NameTableMode: UInt8
    {
        case
        /// On-board VRAM page 0
        onboardVRAMPage0 = 0,
        
        /// On-board VRAM page 1
        onboardVRAMPage1 = 1,
        
        /// Internal Expansion RAM, only if the Extended RAM mode allows it ($5104 is 00/01); otherwise, the nametable will read as all zeros
        internalExpansionRAM = 2,
        
        /// Fill-mode data
        fillModeData = 3
    }
    
    let hasStep: Bool = true
    
    let hasExtendedNametableMapping: Bool = true
    
    var mirroringMode: MirroringMode
    
    /// linear 1D array of all PRG blocks
    private var prg: [UInt8] = []
    
    /// linear 1D array of all CHR blocks
    private var chr: [UInt8] = []
    
    /// 0 - 3
    private var prgMode: UInt8 = 2
    
    /// 0 - 3
    private var chrMode: UInt8 = 3
    
    /// 0 - 3
    private var extendedRamMode: UInt8 = 0
    
    /// the tile number to use when the NameTableMode is fillmodeData.  controlled by register 0x5106
    private var fillModeTile: UInt8 = 0
    
    /// 0 - 3: attribute bits to use when the NameTableMode is fillmodeData.  controller by register 0x5107
    private var fillModeColor: UInt8 = 0
    
    /// NameTable modes for PPU $2000-$23FF, $2400-$27FF, $2800-$2BFF, and $2C00-$2FFF
    private var nameTableModes: [NameTableMode] = [NameTableMode].init(repeating: NameTableMode.onboardVRAMPage0, count: 4)
    
    private var verticalSplitScreenSide: Bool = false
    private var verticalSplitScreenMode: Bool = false
    
    /// 0 - 31
    private var verticalSplitStartStopTile: UInt8 = 0
    
    /// 0 - 15 - select an 8KB range of SRAM within the 128KB total SRAM
    private var sramBank: UInt8 = 0
    
    /// 128KB of SRAM addressible through 0x6000 ... 0x7FFF or 0x8000 ... 0xDFFF, 8KB bank-switched
    private var sram: [UInt8] = [UInt8].init(repeating: 0, count: 1024 * 128)
    
    private var extendedRam: [UInt8] = [UInt8].init(repeating: 0, count: 1024)
    private var onboardVRamPage0: [UInt8] = [UInt8].init(repeating: 0, count: 1024)
    private var onboardVRamPage1: [UInt8] = [UInt8].init(repeating: 0, count: 1024)
    private var requestedInterrupt: Interrupt?
    private var reg5203Value: UInt8 = 0
    private var inFrameFlag: Bool = false
    private var irqEnableFlag: Bool = false
    private var upperChrBankSet: Bool = true
    private var ppuFetchesThisScanline: Int = 0
    private var sprite8x16ModeEnable: Bool = false
    private var ppuCtrl: UInt8 = 0
    private var ppuMask: UInt8 = 0
    
    /// becomes set at any time that the internal scanline counter matches the value written to register $5203
    private var pendingIRQFlag: Bool = false
    
    private var prgOffsets: [Int] = [Int].init(repeating: 0, count: 4)
    private var chrOffsets: [Int] = [Int].init(repeating: 0, count: 12)
    
    init(withCartridge aCartridge: CartridgeProtocol, state aState: MapperState? = nil)
    {
        // TODO: implement restoration from MapperState once MMC5 mapper is working correctly
        self.mirroringMode = aCartridge.header.mirroringMode
        for p in aCartridge.prgBlocks
        {
            self.prg.append(contentsOf: p)
        }

        for c in aCartridge.chrBlocks
        {
            self.chr.append(contentsOf: c)
        }
        
        self.prgOffsets[0] = (aCartridge.prgBlocks.count - 1) * 16384
        self.prgOffsets[1] = (aCartridge.prgBlocks.count - 1) * 16384 + 8192
        self.prgOffsets[2] = (aCartridge.prgBlocks.count - 1) * 16384 + 8192
        self.prgOffsets[3] = (aCartridge.prgBlocks.count - 1) * 16384
    }
    
    // TODO: implement retrieval of MapperState, and restoration from MapperState, once MMC5 mapper is working correctly
    var mapperState: MapperState
    {
        get
        {
            MapperState(mirroringMode: self.mirroringMode.rawValue, ints: [], bools: [], uint8s: [], chr: self.chr)
        }
        set
        {
            self.mirroringMode = MirroringMode.init(rawValue: newValue.mirroringMode) ?? self.mirroringMode
            
            self.chr = newValue.chr
        }
    }
    
    /// read a given mapper address from the CPU (must be an address in the range 0x6000 ... 0xFFFF)
    mutating func cpuRead(address aAddress: UInt16) -> UInt8
    {
        switch aAddress
        {
        case 0x8000 ... 0xFFFF: /// PRG ROM
            if aAddress == 0xFFFA || aAddress == 0xFFFB
            {
                self.inFrameFlag = false
            }
            switch self.prgMode
            {
            case 0:
                /// 32KB switchable PRG ROM
                return self.prg[self.prgOffsets[0] + Int(aAddress - 0x8000)]
            case 1:
                /// $8000-$BFFF: 16 KB switchable PRG ROM / RAM bank
                /// $C000-$FFFF: 16 KB switchable PRG ROM bank
                let bank: Int = Int(aAddress - 0x8000) / 0x4000
                let offset: Int = Int(aAddress % 0x4000)
                return self.prg[self.prgOffsets[bank] + offset]
            case 2:
                /// CPU $8000-$BFFF: 16 KB switchable PRG ROM/RAM bank
                /// CPU $C000-$DFFF: 8 KB switchable PRG ROM/RAM bank
                /// CPU $E000-$FFFF: 8 KB switchable PRG ROM bank
                switch aAddress
                {
                case 0x8000 ... 0xBFFF:
                    return self.prg[self.prgOffsets[0] + Int(aAddress - 0x8000)]
                case 0xC000 ... 0xDFFF:
                    return self.prg[self.prgOffsets[1] + Int(aAddress - 0xC000)]
                case 0xE000 ... 0xFFFF:
                    return self.prg[self.prgOffsets[2] + Int(aAddress - 0xE000)]
                default:
                    return 0
                }
            case 3:
                /// CPU $8000-$9FFF: 8 KB switchable PRG ROM/RAM bank
                /// CPU $A000-$BFFF: 8 KB switchable PRG ROM/RAM bank
                /// CPU $C000-$DFFF: 8 KB switchable PRG ROM/RAM bank
                /// CPU $E000-$FFFF: 8 KB switchable PRG ROM bank
                let bank: Int = Int(aAddress - 0x8000) / 0x2000
                let offset: Int = Int(aAddress % 0x2000)
                return self.prg[self.prgOffsets[bank] + offset]
            default:
                return 0
            }
        case 0x5203: /// Scanline IRQ Compare Value
            /// All eight bits specify the target scanline number at which to generate a scanline IRQ. Value $00 is a special case that will not produce IRQ pending conditions, though it is possible to get an IRQ while this is set to $00 (due to the pending flag being set already.) You will need to take additional measures to fully suppress the IRQ.
            return self.reg5203Value
        case 0x5204: /// Scanline IRQ Status
            /*
             7  bit  0
             ---- ----
             SVxx xxxx  MMC5A default power-on value = $00
             ||
             |+-------- "In Frame" flag
             +--------- Scanline IRQ Pending flag
             */
            let result: UInt8 = (self.pendingIRQFlag ? 0b10000000 : 0) | (self.inFrameFlag ? 0b01000000 : 0)
            self.pendingIRQFlag = false
            self.requestedInterrupt = Interrupt.none
            return result
        case 0x5C00 ... 0x5FFF: /// Extended RAM
            switch self.extendedRamMode
            {
            case 0x02, 0x03:
                return self.extendedRam[Int(aAddress - 0x5C00)]
            default: return 0
            }
        case 0x6000 ... 0x7FFF: /// SRAM
            return self.sram[(Int(self.sramBank) * 0x2000) + (Int(aAddress) - 0x6000)]
        default:
            os_log("unhandled Mapper_MMC5 CPU read at address: 0x%04X", aAddress)
            return 0
        }
    }
    
    mutating func cpuWrite(address aAddress: UInt16, value aValue: UInt8)
    {
        switch aAddress
        {
            case 0x8000 ... 0xFFFF: /// PRG ROM
            switch self.prgMode
            {
            case 0:
                /// 32KB switchable PRG ROM
                self.prg[self.prgOffsets[0] + Int(aAddress - 0x8000)] = aValue
            case 1:
                /// $8000-$BFFF: 16 KB switchable PRG ROM / RAM bank
                /// $C000-$FFFF: 16 KB switchable PRG ROM bank
                let bank: Int = Int(aAddress - 0x8000) / 0x4000
                let offset: Int = Int(aAddress % 0x4000)
                self.prg[self.prgOffsets[bank] + offset] = aValue
            case 2:
                /// CPU $8000-$BFFF: 16 KB switchable PRG ROM/RAM bank
                /// CPU $C000-$DFFF: 8 KB switchable PRG ROM/RAM bank
                /// CPU $E000-$FFFF: 8 KB switchable PRG ROM bank
                switch aAddress
                {
                case 0x8000 ... 0xBFFF:
                    self.prg[self.prgOffsets[0] + Int(aAddress - 0x8000)] = aValue
                case 0xC000 ... 0xDFFF:
                    self.prg[self.prgOffsets[1] + Int(aAddress - 0xC000)] = aValue
                case 0xE000 ... 0xFFFF:
                    self.prg[self.prgOffsets[2] + Int(aAddress - 0xE000)] = aValue
                default:
                    break
                }
            case 3:
                /// CPU $8000-$9FFF: 8 KB switchable PRG ROM/RAM bank
                /// CPU $A000-$BFFF: 8 KB switchable PRG ROM/RAM bank
                /// CPU $C000-$DFFF: 8 KB switchable PRG ROM/RAM bank
                /// CPU $E000-$FFFF: 8 KB switchable PRG ROM bank
                let bank: Int = Int(aAddress - 0x8000) / 0x2000
                let offset: Int = Int(aAddress % 0x2000)
                self.prg[self.prgOffsets[bank] + offset] = aValue
            default:
                break
            }
        case 0x6000 ... 0x7FFF: /// SRAM
            self.sram[(Int(self.sramBank) * 0x2000) + (Int(aAddress) - 0x6000)] = aValue
        case 0x5000 ... 0x5015:
            // TODO: this might be used by Castlevania 3 (for APU-related function?). Investigate
            break
        case 0x5100: /// PRG Banking Mode
            /* PRG MODE
             7  bit  0
             ---- ----
             xxxx xxPP
                    ||
                    ++- Select PRG banking mode
             */
            self.prgMode = aValue & 0x03
        case 0x5101: /// CHR Banking Mode
            /* CHR MODE
             7  bit  0
             ---- ----
             xxxx xxCC
                    ||
                    ++- Select CHR banking mode
             */
            
            self.chrMode = aValue & 0x03
        case 0x5102: /// PRG RAM Protect 1
            /* PRG RAM Protect 1
            7  bit  0
            ---- ----
            xxxx xxWW
                   ||
                   ++- RAM protect 1
            */
            break
        case 0x5103: /// PRG RAM Protect 2
            /* PRG RAM Protect 2
            7  bit  0
            ---- ----
            xxxx xxWW
                   ||
                   ++- RAM protect 2
            */
            break
        case 0x5104: /// Extended RAM Mode
            /* Extended RAM mode
            7  bit  0
            ---- ----
            xxxx xxXX
                   ||
                   ++- Specify extended RAM usage
             */
            /// 0 - Use as extra nametable (possibly for split mode)
            /// 1 - Use as extended attribute data (can also be used as extended nametable)
            /// 2 - Use as ordinary RAM
            /// 3 - Use as ordinary RAM, write protected
            self.extendedRamMode = aValue & 0x03
        case 0x5105: /// Nametable Mapping
            /*
             7  bit  0
             ---- ----
             DDCC BBAA
             |||| ||||
             |||| ||++- Select nametable at PPU $2000-$23FF
             |||| ++--- Select nametable at PPU $2400-$27FF
             ||++------ Select nametable at PPU $2800-$2BFF
             ++-------- Select nametable at PPU $2C00-$2FFF
             */
            /// Nametable values:
            /// 0 - On-board VRAM page 0
            /// 1 - On-board VRAM page 1
            /// 2 - Internal Expansion RAM, only if the Extended RAM mode allows it ($5104 is 00/01); otherwise, the nametable will read as all zeros,
            /// 3 - Fill-mode data
            self.nameTableModes[0] = NameTableMode.init(rawValue: aValue & 0x03) ?? NameTableMode.onboardVRAMPage0
            self.nameTableModes[1] = NameTableMode.init(rawValue: (aValue >> 2) & 0x03) ?? NameTableMode.onboardVRAMPage0
            self.nameTableModes[2] = NameTableMode.init(rawValue: (aValue >> 4) & 0x03) ?? NameTableMode.onboardVRAMPage0
            self.nameTableModes[3] = NameTableMode.init(rawValue: (aValue >> 6) & 0x03) ?? NameTableMode.onboardVRAMPage0
        case 0x5106: /// Fill Mode Tile
            /// All eight bits specify the tile number to use for fill-mode nametable
            self.fillModeTile = aValue
        case 0x5107: /// Fill Mode Tile Attributes
            /* Fill-Mode Nametable Attributes
             7  bit  0
             ---- ----
             xxxx xxAA
                    ||
                    ++- Specify attribute bits to use for fill-mode nametable
             */
            self.fillModeColor = aValue & 0x03
        /* 0x5113 ... 0x5117: PRG Bank Switching
         7  bit  0
         ---- ----
         RAAA AaAA
         |||| ||||
         |||| |||+- PRG ROM/RAM A13
         |||| ||+-- PRG ROM/RAM A14
         |||| |+--- PRG ROM/RAM A15, also selecting between PRG RAM /CE 0 and 1
         |||| +---- PRG ROM/RAM A16
         |||+------ PRG ROM A17
         ||+------- PRG ROM A18
         |+-------- PRG ROM A19
         +--------- RAM/ROM toggle (0: RAM; 1: ROM) (registers $5114-$5116 only)
         */
        ///RAM is always mapped at $6000-$7FFF, and the bit $5113.7 is ignored. ROM is always mapped at the bank controlled by register $5117, and the bit $5117.7 is ignored. This makes it impossible to map RAM at interrupt vectors in any mode.
        ///Modes 0-2 : The bankswitching registers always hold a value of 8kb bank index numbers. When selecting banks of a "larger" size (16 kb or 32kb), the low bits in the bankswitching register are ignored. In other words, the address lines from the CPU are passed through the mapper directly to the PRG-ROM chip.
        ///Games seem to expect $5117 to be $FF at power on. All games have their reset vector in the last bank of PRG ROM, and the vector points to an address greater than or equal to $E000.
        case 0x5113:
            self.sramBank = aValue & 0x0F // get 4 low bits (0 - 15)
        case 0x5114:
            switch self.prgMode
            {
            // TODO: implement other PRG modes
            case 2: break /// prg mode 2: (unused)
            default: break
            }
        case 0x5115:
            switch self.prgMode
            {
            // TODO: implement other PRG modes
            case 2: /// prg mode 2: CPU $8000-$BFFF: 16 KB switchable PRG ROM/RAM bank, indexed from an even multiple of 8KB offset
                let bank: Int = Int(aValue & 0x7F) & ~0x1 // get low 7 bits (0 - 127) and round down to even number
                self.prgOffsets[0] = 8192 * bank
            default:
                break
            }
        case 0x5116:
            switch self.prgMode
            {
            // TODO: implement other PRG modes
            case 2: /// prg mode 2: CPU $C000-$DFFF: 8 KB switchable PRG ROM/RAM bank
                let bank: Int = Int(aValue & 0x7F) // get low 7 bits (0 - 127)
                self.prgOffsets[1] = 8192 * bank
            default:
                break
            }
        case 0x5117:
            switch self.prgMode
            {
            // TODO: implement other PRG modes
            case 2: /// prg mode 2: CPU $E000-$FFFF: 8 KB switchable PRG ROM bank
                let bank: Int = Int(aValue & 0x7F) // get low 7 bits (0 - 127)
                self.prgOffsets[2] = 8192 * bank
            default:
                break
            }
        case 0x5120 ... 0x5127: /// CHR Banking
            switch self.chrMode
            {
            // TODO: implement other CHR modes
            case 3:
                self.chrOffsets[Int(aAddress - 0x5120)] = Int(aValue) * 1024
            default:
                break
            }
        case 0x5128 ... 0x512B: /// CHR Banking
            if self.sprite8x16ModeEnable
            {
                switch self.chrMode
                {
                // TODO: implement other CHR modes
                case 3:
                    self.chrOffsets[Int(aAddress - 0x5120)] = Int(aValue) * 1024
                default:
                    break
                }
            }

        case 0x5130:
            /* Upper CHR Bank Bits (unused by all official games using MMC5)
             7  bit  0
             ---- ----
             xxxx xxBB
                    ||
                    ++- Upper bits for subsequent CHR bank writes
             */
            /// When the MMC5 is using 2KB/1KB CHR banks, only 512KB/256KB of CHR ROM can be selected using the previous registers. To access all 1024KB in those modes, first write the upper bit(s) to register $5130 and then write the lower bits to $5120-$512B. When the Extended RAM mode is set to 1, this selects which 256KB of CHR ROM is to be used for all background tiles on the screen.
            /// The only ExROM game with CHR ROM larger than 256KB is Metal Slader Glory, which uses 4KB CHR banks and does not use extended attributes. In other words, no official game relies on this register, and most don't even initialize it.
            break
        case 0x5200: /// Vertical Split Mode
            /* Vertical Split Mode
             7  bit  0
             ---- ----
             ESxW WWWW
             || | ||||
             || +-++++- Specify vertical split start/stop tile
             |+-------- Specify vertical split screen side (0:left; 1:right)
             +--------- Enable vertical split mode
             */
            /// When vertical split mode is enabled, all VRAM fetches corresponding to the appropriate screen region will be redirected to Extended RAM (as long as its mode is set to 0 or 1).
            /// Uchuu Keibitai SDF uses split screen mode during the intro, where it shows ship stats. Bandit Kings of Ancient China uses split screen mode during the ending sequence[2].
            self.verticalSplitScreenSide = (aValue >> 6) & 1 == 1
            self.verticalSplitScreenMode = (aValue >> 7) & 1 == 1
            self.verticalSplitStartStopTile = aValue & 0x1F
        case 0x5203: /// IRQ Scanline Compare Value
            self.reg5203Value = aValue
        case 0x5204: /// IRQ Scanline Enable Flag
            /* Scanline IRQ Enable
            7  bit  0
            ---- ----
            Exxx xxxx
            |
            +--------- Scanline IRQ Enable flag (1=enable)
            */
            self.irqEnableFlag = (aValue >> 7) & 1 == 1
        case 0x5C00 ... 0x5FFF: /// Extended RAM Write
            /*
            7  bit  0
            ---- ----
            AACC CCCC
            |||| ||||
            ||++-++++- Select 4 KB CHR bank to use with specified tile
            ++-------- Select palette to use with specified tile
            */
            switch self.extendedRamMode
            {
            case 0x03:
                break
            default:
                self.extendedRam[Int(aAddress - 0x5C00)] = aValue
            }
        default:
            os_log("unhandled Mapper_MMC5 CPU write at address (unimplemented): 0x%04X", aAddress)
            break
        }
    }
    
    mutating func ppuRead(address aAddress: UInt16) -> UInt8
    {
        switch aAddress
        {
        case 0x0000 ...  0x1FFF:
            self.ppuFetchesThisScanline += 1
            self.upperChrBankSet = self.ppuFetchesThisScanline <= 64 // TODO: is this number right? it seemed like it should be 34 tiles * 16 bytes per tile
            switch self.chrMode
            {
            case 0:
                /// $0000-$1FFF: 8 KB switchable CHR bank
                return self.chr[self.chrOffsets[0] + Int(aAddress)]
            case 1:
                /// $0000-$0FFF: 4 KB switchable CHR bank
                /// $1000-$1FFF: 4 KB switchable CHR bank
                let bank: Int = Int(aAddress / 0x1000)
                let offset: Int = Int(aAddress % 0x1000)
                return self.chr[self.chrOffsets[bank] + offset]
            case 2:
                /// $0000-$07FF: 2 KB switchable CHR bank
                /// $0800-$0FFF: 2 KB switchable CHR bank
                /// $1000-$17FF: 2 KB switchable CHR bank
                /// $1800-$1FFF: 2 KB switchable CHR bank
                let bank: Int = Int(aAddress / 0x0800)
                let offset: Int = Int(aAddress % 0x0800)
                return self.chr[self.chrOffsets[bank] + offset]
            case 3:
                if self.upperChrBankSet && self.sprite8x16ModeEnable
                {
                    let adjustedAddress: UInt16 = aAddress % 0x1000
                    let bank: Int = 8 + Int(adjustedAddress / 0x0400)
                    let offset: Int = Int(aAddress % 0x0400)
                    return self.chr[self.chrOffsets[bank] + offset]
                }
                else
                {
                    /// $0000-$03FF: 1 KB switchable CHR bank
                    /// $0400-$07FF: 1 KB switchable CHR bank
                    /// $0800-$0BFF: 1 KB switchable CHR bank
                    /// $0C00-$0FFF: 1 KB switchable CHR bank
                    /// $1000-$13FF: 1 KB switchable CHR bank
                    /// $1400-$17FF: 1 KB switchable CHR bank
                    /// $1800-$1BFF: 1 KB switchable CHR bank
                    /// $1C00-$1FFF: 1 KB switchable CHR bank
                    let bank: Int = Int(aAddress / 0x0400)
                    let offset: Int = Int(aAddress % 0x0400)
                    return self.chr[self.chrOffsets[bank] + offset]
                }
                
            default:
                return 0
            }
        case 0x2000 ... 0x2FFF:

            let nameTableMapIndex: Int = Int(aAddress - 0x2000) / 0x400
            let offset: Int = Int(aAddress % 0x400)
            
            switch nameTableModes[nameTableMapIndex]
            {
            case .onboardVRAMPage0:
                let result: UInt8 = self.onboardVRamPage0[offset]
                return result
            case .onboardVRAMPage1:
                let result: UInt8 = self.onboardVRamPage1[offset]
                return result
            case .internalExpansionRAM:
                if self.extendedRamMode <= 1
                {
                    let result: UInt8 = self.extendedRam[offset]
                    return result
                }
                else
                {
                    return 0
                }
            case .fillModeData:
                return 0 // TODO: use fillModeTile and / or fillModeColor bytes?
            }

        default:
            os_log("unhandled Mapper_MMC5 PPU read at address (unimplemented): 0x%04X", aAddress)
            return 0
        }
    }
    
    mutating func ppuWrite(address aAddress: UInt16, value aValue: UInt8)
    {
        switch aAddress
        {
            case 0x0000 ...  0x1FFF:
            switch self.chrMode
            {
            case 0:
                /// $0000-$1FFF: 8 KB switchable CHR bank
                self.chr[self.chrOffsets[0] + Int(aAddress)] = aValue
            case 1:
                /// $0000-$0FFF: 4 KB switchable CHR bank
                /// $1000-$1FFF: 4 KB switchable CHR bank
                let bank: Int = Int(aAddress / 0x1000)
                let offset: Int = Int(aAddress % 0x1000)
                self.chr[self.chrOffsets[bank] + offset] = aValue
            case 2:
                /// $0000-$07FF: 2 KB switchable CHR bank
                /// $0800-$0FFF: 2 KB switchable CHR bank
                /// $1000-$17FF: 2 KB switchable CHR bank
                /// $1800-$1FFF: 2 KB switchable CHR bank
                let bank: Int = Int(aAddress / 0x0800)
                let offset: Int = Int(aAddress % 0x0800)
                self.chr[self.chrOffsets[bank] + offset] = aValue
            case 3:
                if self.upperChrBankSet && self.sprite8x16ModeEnable
                {
                    let adjustedAddress: UInt16 = aAddress % 0x1000
                    let bank: Int = 8 + Int(adjustedAddress / 0x0400)
                    let offset: Int = Int(aAddress % 0x0400)
                    self.chr[self.chrOffsets[bank] + offset] = aValue
                }
                else
                {
                    /// $0000-$03FF: 1 KB switchable CHR bank
                    /// $0400-$07FF: 1 KB switchable CHR bank
                    /// $0800-$0BFF: 1 KB switchable CHR bank
                    /// $0C00-$0FFF: 1 KB switchable CHR bank
                    /// $1000-$13FF: 1 KB switchable CHR bank
                    /// $1400-$17FF: 1 KB switchable CHR bank
                    /// $1800-$1BFF: 1 KB switchable CHR bank
                    /// $1C00-$1FFF: 1 KB switchable CHR bank
                    let bank: Int = Int(aAddress / 0x0400)
                    let offset: Int = Int(aAddress % 0x0400)
                    self.chr[self.chrOffsets[bank] + offset] = aValue
                }
            default: break
            }
        case 0x2000 ... 0x2FFF:

            let nameTableMapIndex: Int = Int(aAddress - 0x2000) / 0x400
            let offset: Int = Int(aAddress % 0x400)
            
            switch nameTableModes[nameTableMapIndex]
            {
            case .onboardVRAMPage0:
                self.onboardVRamPage0[offset] = aValue
            case .onboardVRAMPage1:
                self.onboardVRamPage1[offset] = aValue
            case .internalExpansionRAM:
                if self.extendedRamMode <= 1
                {
                    self.extendedRam[offset] = aValue
                }
                else
                {
                    break
                }
            case .fillModeData:
                break
            }
        
        default:
            os_log("unhandled Mapper_MMC5 PPU write at address (unimplemented): 0x%04X", aAddress)
            break
        }
    }
    
    mutating func ppuControl(value aValue: UInt8)
    {
        self.ppuCtrl = aValue
        if (self.ppuCtrl >> 5) & 1 == 1,
            (self.ppuMask >> 3) & 1 == 1 || (self.ppuMask >> 4) & 1 == 1
        {
            self.sprite8x16ModeEnable = true
        }
        else
        {
            self.sprite8x16ModeEnable = false
        }
    }
    
    mutating func ppuMask(value aValue: UInt8)
    {
        self.ppuMask = aValue
        if (self.ppuCtrl >> 5) & 1 == 1,
            (self.ppuMask >> 3) & 1 == 1 || (self.ppuMask >> 4) & 1 == 1
        {
            self.sprite8x16ModeEnable = true
        }
        else
        {
            self.sprite8x16ModeEnable = false
        }
    }
    
    mutating func step(input aMapperStepInput: MapperStepInput) -> MapperStepResults?
    {
        if aMapperStepInput.ppuCycle == 0
        {
            self.ppuFetchesThisScanline = 0
            self.upperChrBankSet = true
            if self.reg5203Value > 0 && aMapperStepInput.ppuScanline == self.reg5203Value
            {
                self.pendingIRQFlag = true
            }
        }

        self.inFrameFlag = (0 ... 240).contains(aMapperStepInput.ppuScanline)

        let shouldTriggerIrq: Bool = self.pendingIRQFlag && self.irqEnableFlag
        let interrupt: Interrupt? = shouldTriggerIrq ? .irq : self.requestedInterrupt
        self.requestedInterrupt = nil
    
        return MapperStepResults(requestedCPUInterrupt: interrupt)
    }
}
