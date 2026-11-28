//
//  CmdUnPair.swift
//  EquilKit
//
//  Byte-azonos port: AndroidAPS pump/equil manager/command/CmdUnPair.kt
//  Mérvadó forrás: nightscout/AndroidAPS (AGPL-3.0)
//
//  解绑（让泵自己解除配对关系）。port = 0E0E。
//   - sn = name.replace("Equil - ", "").trim() → convertString (每字符前补 "0")
//   - clear1():
//       key   = SHA-256(hexBytes(sn))
//       data  = getEquilPassWord(password)(32) ++ randomPassword(32)
//       model = aesEncrypt(key, data)
//       → responseCmd(model, "0D0D0000")
//   - decode（泵回包后）：
//       content = decrypt(model, randomPassword)    // 128 hex char = 64 byte
//       pwd1 = content[0..64], pwd2 = content[64..]
//       runPwd = pwd2
//       data = hexBytes(pwd1) ++ [0x00 × 32]
//       model2 = aesEncrypt(hexBytes(runPwd), data)
//       → responseCmd(model2, port + runCode)
//   - decodeConfirm: cmdSuccess = true
//
//  注意：解绑是不可逆的。帧序一旦错，泵可能停在半解绑状态，只能用原厂
//  App 复位。所以这条命令只在用户显式确认后发，失败不改本机配对信息。
//

import Foundation
import CryptoKit

final class CmdUnPair: EquilBaseCmd {

    /// 配对时用户输入的 4 位密码（AAPS 的 preferences "password"）。
    let unpairPassword: String
    /// convertString 之后的 SN（每字符前补一个 "0"）。
    var sn: String
    var randomPassword: [UInt8]?

    init(name: String, password: String, createTime: Int64) {
        self.unpairPassword = password
        // 与 CmdPair 同一套规范化：Equil-A1B2C3 / Equil_A1B2C3 / 纯 A1B2C3 都收
        var s = EquilUtils.canonicalName(from: name)
        s = s.replacingOccurrences(of: "Equil - ", with: "")
        s = s.trimmingCharacters(in: .whitespaces)
        var conv = ""
        for ch in s { conv += "0"; conv.append(ch) }
        self.sn = conv
        super.init(createTime: createTime, equilDevice: "", equilPassword: "")
        self.port = "0E0E"
    }

    override var commandLabel: String { "解绑 (CmdUnPair)" }

    // MARK: - 1. üzenet: clear1 / getEquilResponse
    func clear1() throws -> EquilResponse {
        let snBytes = EquilUtils.hexStringToBytes(sn)
        let digest = SHA256.hash(data: Data(snBytes))
        let key = [UInt8](digest)

        let equilPassword = AESUtil.getEquilPassWord(unpairPassword)   // 32 byte
        let rnd = EquilUtils.generateRandomPassword(32)
        randomPassword = rnd
        let data = EquilUtils.concat(equilPassword, rnd)
        let model = try AESUtil.aesEncrypt(key: key, data: data)
        return responseCmd(model, port: "0D0D0000")
    }

    func getEquilResponse() throws -> EquilResponse {
        response = EquilResponse(createTime: createTime)
        return try clear1()
    }

    func getNextEquilResponse() throws -> EquilResponse { try getEquilResponse() }

    override func makeFirstResponse() throws -> EquilResponse { try getEquilResponse() }

    // MARK: - 2. üzenet: decode
    func decode() throws -> EquilResponse? {
        let model = decodeModel()
        guard let keyBytes = randomPassword else { return nil }
        let content = try AESUtil.decrypt(model, key: keyBytes)   // 128 hex char
        guard content.count >= 128 else {
            EquilBaseCmd.dlog("🔬 CmdUnPair: 回包过短 (\(content.count) hex) — 放弃")
            return nil
        }
        let pwd1 = String(content.prefix(64))
        let pwd2 = String(content.suffix(64))     // AAPS: substring(64) 到结尾
        runPwd = pwd2
        let data1 = EquilUtils.hexStringToBytes(pwd1)
        let zeros = [UInt8](repeating: 0x00, count: 32)
        let data = EquilUtils.concat(data1, zeros)
        let model2 = try AESUtil.aesEncrypt(key: EquilUtils.hexStringToBytes(pwd2), data: data)
        runCode = model.code
        return responseCmd(model2, port: port + (runCode ?? ""))
    }

    // MARK: - 3. üzenet: decodeConfirm
    func decodeConfirm() -> EquilResponse? {
        cmdSuccess = true
        return nil
    }

    // MARK: - Beérkező állapotgép bekötése (EquilBaseCmd.decodeEquilPacket hívja)
    override func decodeStep() -> EquilResponse? {
        do { return try decode() }
        catch {
            EquilBaseCmd.dlog("🔬 CmdUnPair decode hiba: \(error)")
            response = EquilResponse(createTime: createTime)
            return nil
        }
    }
    override func decodeConfirmStep() -> EquilResponse? { decodeConfirm() }
}
