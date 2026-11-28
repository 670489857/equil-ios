//
//  EquilBaseSetting.swift
//  EquilKit
//
//  Byte-azonos port: AndroidAPS pump/equil manager/command/BaseSetting.kt
//  Mérvadó forrás: nightscout/AndroidAPS (AGPL-3.0)
//
//  A "setting" parancsok (bólus, temp basal, basal, idő stb.) közös 3-üzenetes
//  kézfogása:
//    1) getEquilResponse  → getReqData (index + device SN), tárolt jelszóval, port 0F0F0000
//    2) decode            → a pump válaszából runPwd = decrypt(...)[8..],
//                           majd getFirstData() runPwd-vel, port port+runCode
//    3) decodeConfirm     → decodeConfirmData (siker jelzés),
//                           majd getNextData() runPwd-vel, port port+runCode
//
//  A getFirstData / getNextData / decodeConfirmData absztrakt — az alosztály adja.
//

import Foundation

class EquilBaseSetting: EquilBaseCmd {

    // MARK: - getReqData (BaseSetting.getReqData)
    /// index(4LE) ++ device SN bytes.  pumpReqIndex++.
    func getReqData() -> [UInt8] {
        let indexByte = EquilUtils.intToBytes(EquilBaseCmd.pumpReqIndex)
        let tzm = EquilUtils.hexStringToBytes(getEquilDevices())
        let data = EquilUtils.concat(indexByte, tzm)
        EquilBaseCmd.pumpReqIndex += 1
        return data
    }

    // MARK: - 1. üzenet: getEquilResponse (BaseSetting.getEquilResponse)
    func getEquilResponse() throws -> EquilResponse {
        config = false
        isEnd = false
        response = EquilResponse(createTime: createTime)
        let pwd = EquilUtils.hexStringToBytes(getEquilPassWord())
        let data = getReqData()
        let model = try AESUtil.aesEncrypt(key: pwd, data: data)
        return responseCmd(model, port: EquilBaseCmd.DEFAULT_PORT + "0000")
    }

    // MARK: - 2. üzenet: decode (BaseSetting.decode)
    /// A pump válaszának feldolgozása után küldi a tényleges payloadot (getFirstData).
    /// A `respModel` a beérkezett csomagokból decodeModel()-lel állítható elő.
    func decode() throws -> EquilResponse {
        let reqModel = decodeModel()
        EquilBaseCmd.dlog("🔬 decode(): reqModel.code=\(reqModel.code ?? "nil") iv=\(reqModel.iv?.prefix(8) ?? "")… ct.len=\((reqModel.ciphertext?.count ?? 0)/2)B")
        let pwd = EquilUtils.hexStringToBytes(getEquilPassWord())
        let content = try AESUtil.decrypt(reqModel, key: pwd)
        EquilBaseCmd.dlog("🔬 Msg1 content(hex)=\(content)")
        // content HEX string; substring(8) = az első 4 byte (8 hex char) levágása
        let pwd2 = String(content.dropFirst(8))
        runPwd = pwd2
        EquilBaseCmd.dlog("🔬 runPwd(pwd2)=\(pwd2)  hossz=\(pwd2.count) hexchar (=\(pwd2.count/2)B)")
        guard let firstData = getFirstData() else {
            throw EquilError.invalidState("getFirstData nil")
        }
        EquilBaseCmd.dlog("🔬 getFirstData=\(EquilUtils.bytesToHex(firstData)) (\(firstData.count)B)")
        let model = try AESUtil.aesEncrypt(key: EquilUtils.hexStringToBytes(pwd2), data: firstData)
        runCode = reqModel.code
        EquilBaseCmd.dlog("🔬 Msg2 port=\(port + (runCode ?? "")) tag=\(model.tag?.prefix(8) ?? "")… ct.len=\((model.ciphertext?.count ?? 0)/2)B")
        return responseCmd(model, port: port + (runCode ?? ""))
    }

    // MARK: - EquilCommandDriving felülírás (minden setting-parancs az első üzenettel indul)
    override func makeFirstResponse() throws -> EquilResponse { try getEquilResponse() }

    /// AAPS `EquilBLE.writeCmd`：连接还活着时，把上一条命令的 runCode/runPwd
    /// 塞给新命令，然后走 `nextCmd2()` —— 即下面的 getNextEquilResponse()。
    ///
    /// 泵只在新 GATT 会话的第一个命令里接受「请求 → 回密钥 → 再发」这套协商；
    /// 同一条连接上再走一遍，泵会把报文当重放、一个包都不回 —— 这正是
    /// 「第一轮排气能过、第二轮卡住」的原因。
    override func reuseSessionResponse(pwd: String, code: String?) throws -> EquilResponse {
        runPwd = pwd
        runCode = code
        return try getNextEquilResponse()
    }

    // MARK: - getNextEquilResponse (BaseSetting.getNextEquilResponse)
    func getNextEquilResponse() throws -> EquilResponse {
        config = true
        isEnd = false
        response = EquilResponse(createTime: createTime)
        guard let firstData = getFirstData() else {
            throw EquilError.invalidState("getFirstData nil")
        }
        guard let runPwd = runPwd else { throw EquilError.invalidState("runPwd nil") }
        let model = try AESUtil.aesEncrypt(key: EquilUtils.hexStringToBytes(runPwd), data: firstData)
        return responseCmd(model, port: port + (runCode ?? ""))
    }

    // MARK: - 3. üzenet: decodeConfirm (BaseSetting.decodeConfirm)
    /// 确认阶段是否还要下发第 3 条报文。AAPS 的 `BaseSetting.decodeConfirm` 默认发，
    /// 只有 `CmdStepSet` 覆盖成「sendConfig == true 才发」。
    /// 排气用的正是 `CmdStepSet(sendConfig: false)` —— 多发的这条确认包会让泵
    /// 在同一个会话里不再理下一条命令，表现为「第 2 步起不回包」。
    var sendsConfirmPacket: Bool { true }

    func decodeConfirm() throws -> EquilResponse {
        let model = decodeModel()
        runCode = model.code
        guard let runPwd = runPwd else { throw EquilError.invalidState("runPwd nil") }
        let content = try AESUtil.decrypt(model, key: EquilUtils.hexStringToBytes(runPwd))
        decodeConfirmData(EquilUtils.hexStringToBytes(content))
        // 空列表 = 没有下一条报文（runner 只在 next.send 非空时才发）。
        guard sendsConfirmPacket else { return EquilResponse(createTime: createTime) }
        guard let nextData = getNextData() else {
            throw EquilError.invalidState("getNextData nil")
        }
        let model2 = try AESUtil.aesEncrypt(key: EquilUtils.hexStringToBytes(runPwd), data: nextData)
        return responseCmd(model2, port: port + (runCode ?? ""))
    }

    // MARK: - Absztrakt (alosztály felülírja)
    func getFirstData() -> [UInt8]? { nil }
    func getNextData() -> [UInt8]? { nil }
    func decodeConfirmData(_ data: [UInt8]) {}

    // MARK: - Beérkező állapotgép bekötése (EquilBaseCmd.decodeEquilPacket hívja)
    /// 1. fázis lezárása: a pump válaszából runPwd, majd getFirstData payload.
    override func decodeStep() -> EquilResponse? {
        do { return try decode() }
        catch { response = EquilResponse(createTime: createTime); return nil }
    }
    /// 2. fázis lezárása: decodeConfirmData (siker), majd getNextData.
    override func decodeConfirmStep() -> EquilResponse? {
        do { return try decodeConfirm() }
        catch { response = EquilResponse(createTime: createTime); return nil }
    }
}
