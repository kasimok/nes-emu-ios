//
//  Mapper_MMC2.swift
//  nes-emu-ios
//
//  Created by Tom Salvo on 6/18/20.
//  Copyright © 2020 Tom Salvo. All rights reserved.
//

import Foundation
import os

class Mapper_MMC2: MapperProtocol
{
    var mirroringMode: MirroringMode
    
    /// linear 1D array of all PRG blocks
    private var prg: [UInt8] = []
    
    /// linear 1D array of all CHR blocks
    private var chr: [UInt8] = []
    
    /// 8KB of SRAM addressible through 0x6000 ... 0x7FFF
    private var sram: [UInt8] = [UInt8].init(repeating: 0, count: 8192)
    
    private var chrLatch1: Int = 1
    private var chrLatch2: Int = 1
    private var chrBanks1: [Int] = [0, 0]
    private var chrBanks2: [Int] = [1, 0]
    private var prgBank1: Int = 0 // switch between different 8KB PRG Banks
    private let prgBank2: Int // fixed to last 3x 8KB PRG banks
    
    init(withCartridge aCartridge: CartridgeProtocol)
    {
        self.mirroringMode = aCartridge.header.mirroringMode
        
        for p in aCartridge.prgBlocks
        {
            self.prg.append(contentsOf: p)
        }
        
        self.prgBank2 = max((aCartridge.prgBlocks.count * 16384) - (3 * 8192), 0)
        
        for c in aCartridge.chrBlocks
        {
            self.chr.append(contentsOf: c)
        }
        
        if self.chr.count == 0
        {
            // use a block for CHR RAM if no block exists
            self.chr.append(contentsOf: [UInt8].init(repeating: 0, count: 8192))
        }

    }
    
    func read(address aAddress: UInt16) -> UInt8
    {
        switch aAddress
        {
        case 0x0000 ..< 0x1000: // 4KB Switchable CHR Bank 1
            let result =  self.chr[Int(self.chrBanks1[chrLatch1] * 0x1000) + Int(aAddress)]
            self.updateChrLatch1(forAddress: aAddress)
            return result
        case 0x1000 ..< 0x2000: // 4KB Switchable CHR Bank 2
            let result = self.chr[Int(self.chrBanks2[chrLatch2] * 0x1000) + Int(aAddress - 0x1000)]
            self.updateChrLatch2(forAddress: aAddress)
            return result
        case 0x8000 ..< 0xA000: // 8KB Switchable PRG Bank
            return self.prg[Int(self.prgBank1 * 0x2000) + Int(aAddress - 0x8000)]
        case 0xA000 ... 0xFFFF: // Fixed 24KB PRG
            return self.prg[self.prgBank2 + Int(aAddress - 0xA000)]
        case 0x6000 ..< 0x8000:
            return self.sram[Int(aAddress - 0x6000)]
        default:
            os_log("unhandled Mapper_MMC2 read at address: 0x%04X", aAddress)
            return 0
        }
    }
    
    func write(address aAddress: UInt16, value aValue: UInt8)
    {
        switch aAddress
        {
        case 0xA000 ..< 0xB000: // select 8KB PRG Bank 0-15 xxxxPPPP for CPU 0x8000-0x9FFF
            self.prgBank1 = Int(aValue % 0x0F)
        case 0xB000 ..< 0xC000: // Select 4 KB CHR ROM bank 1 0-31 xxxCCCCC for PPU $0000-$0FFF
            self.chrBanks1[0] = Int(aValue % 0x20)
        case 0xC000 ..< 0xD000: // Select 4 KB CHR ROM bank 1 0-31 xxxCCCCC for PPU $0000-$0FFF
            self.chrBanks1[1] = Int(aValue % 0x20)
        case 0xD000 ..< 0xE000: // Select 4 KB CHR ROM bank 2 0-31 xxxCCCCC for PPU $1000-$1FFF when latch2 == 1
            self.chrBanks2[0] = Int(aValue % 0x20)
        case 0xE000 ..< 0xF000: // Select 4 KB CHR ROM bank 2 0-31 xxxCCCCC for PPU $1000-$1FFF
            self.chrBanks2[1] = Int(aValue % 0x20)
        case 0xF000 ... 0xFFFF:
            self.mirroringMode = (aValue % 0x02) == 0 ? .vertical : .horizontal
        default:
            os_log("unhandled Mapper_MMC2 write at address: 0x%04X", aAddress)
            break
        }
    }
    
    func step(ppu aPPU: PPUProtocol?, cpu aCPU: CPUProtocol?)
    {
        
    }
    
    private func updateChrLatch1(forAddress aAddress: UInt16)
    {
        switch aAddress
        {
        case 0x0FD8:
            self.chrLatch1 = 0
        case 0x0FE8:
            self.chrLatch1 = 1
        default: break
        }
    }
    
    private func updateChrLatch2(forAddress aAddress: UInt16)
    {
        switch aAddress
        {
        case 0x1FD8 ... 0x1FDF:
            self.chrLatch2 = 0
        case 0x1FE8 ... 0x1FEF:
            self.chrLatch2 = 1
        default: break
        }
    }
}