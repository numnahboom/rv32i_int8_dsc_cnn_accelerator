#!/usr/bin/env python3
"""Generate a six-slide editable PPTX for the RV32I CNN accelerator project.

The script intentionally uses only the Python standard library. It writes a
minimal OpenXML presentation with native text and shape objects, so the deck is
editable in PowerPoint/WPS/LibreOffice without requiring python-pptx.
"""

from __future__ import annotations

import html
import zipfile
from pathlib import Path


ROOT = Path(__file__).resolve().parents[1]
OUT = ROOT / "docs" / "rv32i_int8_cnn_project_ppt.pptx"
CHECK = ROOT / "build" / "reports" / "ppt_openxml_check.txt"

EMU = 914400
SLIDE_W = int(13.333333 * EMU)
SLIDE_H = int(7.5 * EMU)

NS = {
    "a": "http://schemas.openxmlformats.org/drawingml/2006/main",
    "r": "http://schemas.openxmlformats.org/officeDocument/2006/relationships",
    "p": "http://schemas.openxmlformats.org/presentationml/2006/main",
}


def emu(value: float) -> int:
    return int(value * EMU)


def esc(text: str) -> str:
    return html.escape(text, quote=False)


class SlideBuilder:
    def __init__(self, bg: str = "F7F8FA") -> None:
        self.parts: list[str] = []
        self.next_id = 2
        self.bg = bg
        self.rect(0, 0, 13.333, 7.5, fill=bg, line=None, name="Background")

    def _id(self) -> int:
        value = self.next_id
        self.next_id += 1
        return value

    def rect(
        self,
        x: float,
        y: float,
        w: float,
        h: float,
        fill: str | None,
        line: str | None = "D0D5DD",
        radius: bool = False,
        name: str = "Shape",
    ) -> None:
        sid = self._id()
        geom = "roundRect" if radius else "rect"
        fill_xml = "<a:noFill/>" if fill is None else f"<a:solidFill><a:srgbClr val=\"{fill}\"/></a:solidFill>"
        line_xml = "<a:ln><a:noFill/></a:ln>" if line is None else (
            f"<a:ln w=\"9525\"><a:solidFill><a:srgbClr val=\"{line}\"/></a:solidFill></a:ln>"
        )
        self.parts.append(
            f"""
<p:sp>
  <p:nvSpPr><p:cNvPr id="{sid}" name="{esc(name)}"/><p:cNvSpPr/><p:nvPr/></p:nvSpPr>
  <p:spPr>
    <a:xfrm><a:off x="{emu(x)}" y="{emu(y)}"/><a:ext cx="{emu(w)}" cy="{emu(h)}"/></a:xfrm>
    <a:prstGeom prst="{geom}"><a:avLst/></a:prstGeom>
    {fill_xml}
    {line_xml}
  </p:spPr>
  <p:txBody><a:bodyPr/><a:lstStyle/><a:p/></p:txBody>
</p:sp>"""
        )

    def text(
        self,
        x: float,
        y: float,
        w: float,
        h: float,
        text: str,
        size: int = 24,
        color: str = "101828",
        bold: bool = False,
        align: str = "l",
        name: str = "Text",
    ) -> None:
        sid = self._id()
        paras = text.split("\n")
        p_xml = []
        for para in paras:
            para = para.rstrip()
            p_xml.append(
                f"""
    <a:p>
      <a:pPr algn="{align}"/>
      <a:r>
        <a:rPr lang="zh-CN" sz="{size * 100}" b="{1 if bold else 0}">
          <a:solidFill><a:srgbClr val="{color}"/></a:solidFill>
          <a:latin typeface="Microsoft YaHei"/>
          <a:ea typeface="Microsoft YaHei"/>
        </a:rPr>
        <a:t>{esc(para)}</a:t>
      </a:r>
    </a:p>"""
            )
        self.parts.append(
            f"""
<p:sp>
  <p:nvSpPr><p:cNvPr id="{sid}" name="{esc(name)}"/><p:cNvSpPr txBox="1"/><p:nvPr/></p:nvSpPr>
  <p:spPr>
    <a:xfrm><a:off x="{emu(x)}" y="{emu(y)}"/><a:ext cx="{emu(w)}" cy="{emu(h)}"/></a:xfrm>
    <a:prstGeom prst="rect"><a:avLst/></a:prstGeom>
    <a:noFill/><a:ln><a:noFill/></a:ln>
  </p:spPr>
  <p:txBody>
    <a:bodyPr wrap="square" lIns="0" tIns="0" rIns="0" bIns="0"/>
    <a:lstStyle/>
    {''.join(p_xml)}
  </p:txBody>
</p:sp>"""
        )

    def box_text(
        self,
        x: float,
        y: float,
        w: float,
        h: float,
        text: str,
        fill: str,
        line: str = "D0D5DD",
        size: int = 16,
        color: str = "101828",
        bold: bool = False,
        radius: bool = True,
        align: str = "ctr",
    ) -> None:
        self.rect(x, y, w, h, fill=fill, line=line, radius=radius)
        self.text(x + 0.08, y + 0.08, w - 0.16, h - 0.16, text, size=size, color=color, bold=bold, align=align)

    def line(self, x: float, y: float, w: float, h: float, color: str = "475467") -> None:
        if abs(w) >= abs(h):
            self.rect(x, y, w, 0.025, fill=color, line=None, name="Line")
        else:
            self.rect(x, y, 0.025, h, fill=color, line=None, name="Line")

    def arrow_label(self, x: float, y: float, label: str = "→", color: str = "475467") -> None:
        self.text(x, y, 0.35, 0.25, label, size=18, color=color, bold=True, align="ctr")

    def xml(self) -> str:
        return f"""<?xml version="1.0" encoding="UTF-8" standalone="yes"?>
<p:sld xmlns:a="{NS['a']}" xmlns:r="{NS['r']}" xmlns:p="{NS['p']}">
  <p:cSld>
    <p:spTree>
      <p:nvGrpSpPr><p:cNvPr id="1" name=""/><p:cNvGrpSpPr/><p:nvPr/></p:nvGrpSpPr>
      <p:grpSpPr><a:xfrm><a:off x="0" y="0"/><a:ext cx="0" cy="0"/><a:chOff x="0" y="0"/><a:chExt cx="0" cy="0"/></a:xfrm></p:grpSpPr>
      {''.join(self.parts)}
    </p:spTree>
  </p:cSld>
  <p:clrMapOvr><a:masterClrMapping/></p:clrMapOvr>
</p:sld>
"""


def title(slide: SlideBuilder, text: str, subtitle: str | None = None) -> None:
    slide.text(0.55, 0.35, 8.9, 0.45, text, size=28, bold=True)
    if subtitle:
        slide.text(0.58, 0.83, 7.2, 0.28, subtitle, size=12, color="667085")


def slide_cover() -> SlideBuilder:
    s = SlideBuilder("F7F8FA")
    s.rect(0.0, 0.0, 4.3, 7.5, fill="101828", line=None)
    s.text(0.62, 0.58, 3.0, 0.28, "EDGE INT8 INFERENCE", size=12, color="98A2B3", bold=True)
    s.text(0.62, 1.22, 5.7, 1.55, "RV32I 自定义指令\nCNN 加速器", size=36, color="FFFFFF", bold=True)
    s.text(0.65, 3.13, 4.9, 0.7, "Depthwise-separable CNN datapath\nfor CIFAR-10 EdgeDSCNet-C10", size=17, color="D0D5DD")
    s.box_text(6.0, 1.03, 2.0, 0.72, "1.09M\nRTL cycles", "EAF6EF", "A6D7B8", 18, "14532D", True)
    s.box_text(8.35, 1.03, 2.1, 0.72, "100%\nlogit match", "EAF0FF", "B7C9FF", 18, "1D3D8F", True)
    s.box_text(10.8, 1.03, 1.85, 0.72, "314x\nestimate", "FFF5E6", "FFD89B", 18, "7A4100", True)
    s.text(5.9, 2.35, 6.25, 1.35, "CPU issues cnn.start, cnn.poll, and cnn.stat.\ncnn_top fetches descriptors, runs Stem / DSBlock / GAP / FC,\nand writes logits back for firmware argmax.", size=18, color="101828")
    s.line(5.9, 4.4, 5.9, 0.0, "98A2B3")
    s.text(5.9, 4.72, 5.9, 0.75, "交付物: 架构图、验证闭环图、综合尝试报告、6 页项目 PPT、已知限制与后续优化。", size=17, color="344054", bold=True)
    s.text(5.9, 6.85, 5.4, 0.25, "rv32i_int8_dsc_cnn_accelerator", size=12, color="667085")
    return s


def slide_problem() -> SlideBuilder:
    s = SlideBuilder()
    title(s, "问题与目标", "CPU-only int8 CNN 太慢，目标是让 RV32I 发起并监督硬件推理")
    s.text(0.75, 1.45, 4.0, 0.75, "问题", size=28, bold=True, color="B42318")
    s.text(0.8, 2.2, 4.4, 2.8, "• RV32I 无乘法扩展时，CNN MAC 和 requant 成本很高\n• DW/PW 中间 feature map 若频繁写外存，会浪费带宽\n• CPU 接口不能长时间阻塞流水线 EX 阶段\n• 验证必须覆盖 Python golden 到 CPU 联合仿真闭环", size=18, color="344054")
    s.text(7.05, 1.45, 4.0, 0.75, "目标", size=28, bold=True, color="175CD3")
    s.text(7.1, 2.2, 4.9, 2.8, "• custom instruction 控制 cnn_top\n• int8 activation / weight，int32 accumulator\n• DW3x3 tile fusion，不写回完整 DW 中间图\n• PW1x1 使用 8x8 array\n• CIFAR-10 EdgeDSCNet-C10 fullnet smoke 与 golden 完全一致", size=18, color="344054")
    s.rect(0.7, 5.65, 11.9, 0.02, fill="D0D5DD", line=None)
    s.text(0.78, 6.05, 11.3, 0.48, "固定网络: Stem -> 6x DSBlock -> GAP -> FC, 输出 10 类 logits", size=20, color="101828", bold=True, align="ctr")
    return s


def slide_architecture() -> SlideBuilder:
    s = SlideBuilder()
    title(s, "架构图", "CPU 控制面与 cnn_top 数据面分离")
    s.box_text(0.55, 1.25, 1.6, 0.62, "RV32I\nCPU", "F2F4F7", size=16, bold=True)
    s.arrow_label(2.2, 1.42)
    s.box_text(2.65, 1.25, 2.0, 0.62, "custom instruction\nstart / poll / stat", "EAF0FF", "B7C9FF", size=12, bold=True)
    s.arrow_label(4.75, 1.42)
    s.box_text(5.15, 1.25, 1.85, 0.62, "npc bridge\nrv_cnn_if", "EAF6EF", "A6D7B8", size=13, bold=True)
    s.arrow_label(7.05, 1.42)
    s.box_text(7.45, 0.95, 4.9, 4.95, "cnn_top", "FFFFFF", "667085", size=22, bold=True)

    s.box_text(7.85, 1.65, 1.45, 0.52, "descriptor\nfetch", "F9FAFB", size=11, bold=True)
    s.box_text(9.45, 1.65, 1.35, 0.52, "top ctrl", "F9FAFB", size=11, bold=True)
    s.box_text(10.95, 1.65, 1.0, 0.52, "status", "F9FAFB", size=11, bold=True)
    s.box_text(8.25, 2.55, 2.85, 0.56, "cnn_layer_runner", "FFF5E6", "FFD89B", size=13, bold=True)
    s.box_text(7.9, 3.45, 2.0, 0.56, "SRAM A/B\nping-pong", "F0F9FF", "B9E6FE", size=12, bold=True)
    s.box_text(10.25, 3.45, 1.7, 0.56, "DW tile\nbuffer", "FDF2FA", "FCCEEE", size=12, bold=True)
    s.box_text(7.9, 4.45, 1.35, 0.5, "Stem", "F9FAFB", size=11)
    s.box_text(9.42, 4.45, 1.25, 0.5, "DW3x3", "F9FAFB", size=11)
    s.box_text(10.85, 4.45, 1.25, 0.5, "PW8x8", "F9FAFB", size=11)
    s.box_text(9.05, 5.15, 1.15, 0.46, "GAP", "F9FAFB", size=11)
    s.box_text(10.45, 5.15, 1.15, 0.46, "FC", "F9FAFB", size=11)

    s.box_text(0.75, 3.15, 2.5, 0.65, "Descriptor memory\n32 words/layer", "FFFFFF", "D0D5DD", size=13)
    s.box_text(0.75, 4.45, 2.5, 0.65, "External memory\ninput / weights / logits", "FFFFFF", "D0D5DD", size=13)
    s.arrow_label(3.45, 3.32)
    s.arrow_label(3.45, 4.62)
    s.text(0.75, 6.55, 11.5, 0.32, "设计边界: DW 中间结果只进入 DW tile buffer；PW 直接消费 tile buffer；CPU 只通过命令和状态观察推理。", size=15, color="344054")
    return s


def slide_dataflow() -> SlideBuilder:
    s = SlideBuilder()
    title(s, "数据流", "从输入图像到 logits 的模块流动")
    labels = [
        ("Input\nNHWC int8", "FFFFFF"),
        ("Conv3x3\nStem", "EAF0FF"),
        ("SRAM\nping-pong", "F0F9FF"),
        ("DW tile\nfusion", "FFF5E6"),
        ("DW tile\nbuffer", "FDF2FA"),
        ("PW 8x8\narray", "EAF6EF"),
        ("SRAM\nping-pong", "F0F9FF"),
        ("GAP", "FFFFFF"),
        ("FC\nlogits", "FFFFFF"),
    ]
    x = 0.45
    for idx, (label, fill) in enumerate(labels):
        w = 1.22 if idx not in (2, 6) else 1.35
        s.box_text(x, 2.15, w, 0.85, label, fill, "C7CDD8", size=12, bold=True)
        if idx < len(labels) - 1:
            s.arrow_label(x + w + 0.08, 2.42)
        x += w + 0.35
    s.text(1.05, 3.75, 3.1, 0.8, "Stem output writes SRAM A/B.\nNext descriptor chooses SRAM input and output side.", size=15, color="344054")
    s.text(4.8, 3.75, 3.3, 0.8, "DW computes one tile with halo.\nPadding uses input_zero_point.", size=15, color="344054")
    s.text(8.8, 3.75, 3.2, 0.8, "PW consumes 8 pixels x 8 cout.\nRequant + ReLU6 then store.", size=15, color="344054")
    s.rect(4.55, 1.45, 3.6, 2.05, fill=None, line="F79009", radius=True)
    s.text(4.9, 1.58, 3.0, 0.25, "DSBlock tile fusion region", size=13, color="B54708", bold=True, align="ctr")
    s.text(0.9, 5.75, 11.4, 0.58, "当前 v1 输出写回格式: 每个 int8 output element 写入一个 32-bit word 的低 8 位，便于 RTL smoke 对比。", size=18, color="101828", bold=True, align="ctr")
    return s


def slide_verification() -> SlideBuilder:
    s = SlideBuilder()
    title(s, "验证闭环", "从训练模型到 CPU 联合仿真的同一组 int8 语义")
    steps = [
        ("PyTorch\ntrain", "F2F4F7"),
        ("quantize\nexport", "EAF0FF"),
        ("Python\nint8 golden", "EAF6EF"),
        ("RTL\nmodules", "FFF5E6"),
        ("Verilator\nsimulation", "FDF2FA"),
        ("logits\ncompare", "FFFFFF"),
        ("firmware /\nCPU joint sim", "F0F9FF"),
    ]
    x = 0.42
    for i, (label, fill) in enumerate(steps):
        s.box_text(x, 2.0, 1.35, 0.88, label, fill, "C7CDD8", size=12, bold=True)
        if i < len(steps) - 1:
            s.arrow_label(x + 1.42, 2.29)
        x += 1.82
    s.text(0.78, 3.55, 3.7, 1.25, "单元级\n• requant\n• PW array\n• DW tile fusion\n• Stem / GAP / FC", size=17, color="344054")
    s.text(4.9, 3.55, 3.7, 1.25, "顶层级\n• descriptor fetch\n• SRAM tiled datapath\n• fullnet smoke\n• logits exact match", size=17, color="344054")
    s.text(8.95, 3.55, 3.6, 1.25, "CPU 级\n• custom start\n• poll done\n• stat cycles\n• firmware argmax", size=17, color="344054")
    s.box_text(1.0, 5.75, 10.9, 0.62, "验收核心: RTL 输出 10 个 logits 与 Python golden 逐元素一致，然后 CPU 看到相同 argmax。", "FFFFFF", "98A2B3", size=18, bold=True)
    return s


def slide_results() -> SlideBuilder:
    s = SlideBuilder()
    title(s, "结果、综合状态与限制", "功能闭环已跑通；真实综合工具本机未安装，已补可复现实验脚本")
    s.box_text(0.75, 1.3, 2.15, 0.82, "1,085,562\nhardware cycles", "EAF6EF", "A6D7B8", 18, "14532D", True)
    s.box_text(3.2, 1.3, 2.15, 0.82, "100%\nlogit match", "EAF0FF", "B7C9FF", 18, "1D3D8F", True)
    s.box_text(5.65, 1.3, 2.15, 0.82, "341M\nRV32I estimate", "FFF5E6", "FFD89B", 18, "7A4100", True)
    s.box_text(8.1, 1.3, 2.15, 0.82, "314x\nspeedup estimate", "FDF2FA", "FCCEEE", 18, "851651", True)
    s.text(0.86, 2.65, 5.5, 1.6, "真实综合尝试\n• Windows PATH: Yosys/Vivado not found\n• WSL: yosys/vivado command not found\n• 已新增 scripts/run_synthesis_yosys.sh\n• 报告: build/reports/synthesis_initial.md", size=17, color="344054")
    s.text(7.0, 2.65, 4.95, 1.6, "当前限制\n• word-per-int8 仿真内存格式\n• SRAM/BRAM inference 待综合确认\n• 单时钟，未做 CDC\n• 约 50% checkpoint 用于功能验证", size=17, color="344054")
    s.rect(0.75, 5.15, 11.5, 0.02, fill="D0D5DD", line=None)
    s.text(0.9, 5.55, 11.1, 0.75, "下一步: 跑真实 FPGA synthesis，确认 BRAM/DSP/timing；再做 requant 流水化、PW 控制复制、packed NHWC loader、QAT/calibration。", size=19, color="101828", bold=True, align="ctr")
    return s


def presentation_xml(slide_count: int) -> str:
    sld_ids = "\n".join(
        f'<p:sldId id="{255 + i}" r:id="rId{i + 2}"/>' for i in range(1, slide_count + 1)
    )
    return f"""<?xml version="1.0" encoding="UTF-8" standalone="yes"?>
<p:presentation xmlns:a="{NS['a']}" xmlns:r="{NS['r']}" xmlns:p="{NS['p']}">
  <p:sldMasterIdLst><p:sldMasterId id="2147483648" r:id="rId1"/></p:sldMasterIdLst>
  <p:sldIdLst>{sld_ids}</p:sldIdLst>
  <p:sldSz cx="{SLIDE_W}" cy="{SLIDE_H}" type="wide"/>
  <p:notesSz cx="6858000" cy="9144000"/>
  <p:defaultTextStyle/>
</p:presentation>
"""


def presentation_rels(slide_count: int) -> str:
    rels = [
        '<Relationship Id="rId1" Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/slideMaster" Target="slideMasters/slideMaster1.xml"/>'
    ]
    for i in range(1, slide_count + 1):
        rels.append(
            f'<Relationship Id="rId{i + 1}" Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/slide" Target="slides/slide{i}.xml"/>'
        )
    rels.append(
        f'<Relationship Id="rId{slide_count + 2}" Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/theme" Target="theme/theme1.xml"/>'
    )
    return '<?xml version="1.0" encoding="UTF-8" standalone="yes"?><Relationships xmlns="http://schemas.openxmlformats.org/package/2006/relationships">' + "".join(rels) + "</Relationships>"


def content_types(slide_count: int) -> str:
    overrides = [
        '<Default Extension="rels" ContentType="application/vnd.openxmlformats-package.relationships+xml"/>',
        '<Default Extension="xml" ContentType="application/xml"/>',
        '<Override PartName="/ppt/presentation.xml" ContentType="application/vnd.openxmlformats-officedocument.presentationml.presentation.main+xml"/>',
        '<Override PartName="/ppt/slideMasters/slideMaster1.xml" ContentType="application/vnd.openxmlformats-officedocument.presentationml.slideMaster+xml"/>',
        '<Override PartName="/ppt/slideLayouts/slideLayout1.xml" ContentType="application/vnd.openxmlformats-officedocument.presentationml.slideLayout+xml"/>',
        '<Override PartName="/ppt/theme/theme1.xml" ContentType="application/vnd.openxmlformats-officedocument.theme+xml"/>',
        '<Override PartName="/docProps/core.xml" ContentType="application/vnd.openxmlformats-package.core-properties+xml"/>',
        '<Override PartName="/docProps/app.xml" ContentType="application/vnd.openxmlformats-officedocument.extended-properties+xml"/>',
    ]
    for i in range(1, slide_count + 1):
        overrides.append(
            f'<Override PartName="/ppt/slides/slide{i}.xml" ContentType="application/vnd.openxmlformats-officedocument.presentationml.slide+xml"/>'
        )
    return '<?xml version="1.0" encoding="UTF-8" standalone="yes"?><Types xmlns="http://schemas.openxmlformats.org/package/2006/content-types">' + "".join(overrides) + "</Types>"


SLIDE_LAYOUT = """<?xml version="1.0" encoding="UTF-8" standalone="yes"?>
<p:sldLayout xmlns:a="http://schemas.openxmlformats.org/drawingml/2006/main" xmlns:r="http://schemas.openxmlformats.org/officeDocument/2006/relationships" xmlns:p="http://schemas.openxmlformats.org/presentationml/2006/main" type="blank" preserve="1">
  <p:cSld name="Blank"><p:spTree><p:nvGrpSpPr><p:cNvPr id="1" name=""/><p:cNvGrpSpPr/><p:nvPr/></p:nvGrpSpPr><p:grpSpPr><a:xfrm><a:off x="0" y="0"/><a:ext cx="0" cy="0"/><a:chOff x="0" y="0"/><a:chExt cx="0" cy="0"/></a:xfrm></p:grpSpPr></p:spTree></p:cSld>
  <p:clrMapOvr><a:masterClrMapping/></p:clrMapOvr>
</p:sldLayout>
"""

SLIDE_MASTER = """<?xml version="1.0" encoding="UTF-8" standalone="yes"?>
<p:sldMaster xmlns:a="http://schemas.openxmlformats.org/drawingml/2006/main" xmlns:r="http://schemas.openxmlformats.org/officeDocument/2006/relationships" xmlns:p="http://schemas.openxmlformats.org/presentationml/2006/main">
  <p:cSld><p:spTree><p:nvGrpSpPr><p:cNvPr id="1" name=""/><p:cNvGrpSpPr/><p:nvPr/></p:nvGrpSpPr><p:grpSpPr><a:xfrm><a:off x="0" y="0"/><a:ext cx="0" cy="0"/><a:chOff x="0" y="0"/><a:chExt cx="0" cy="0"/></a:xfrm></p:grpSpPr></p:spTree></p:cSld>
  <p:clrMap bg1="lt1" tx1="dk1" bg2="lt2" tx2="dk2" accent1="accent1" accent2="accent2" accent3="accent3" accent4="accent4" accent5="accent5" accent6="accent6" hlink="hlink" folHlink="folHlink"/>
  <p:sldLayoutIdLst><p:sldLayoutId id="2147483649" r:id="rId1"/></p:sldLayoutIdLst>
  <p:txStyles><p:titleStyle/><p:bodyStyle/><p:otherStyle/></p:txStyles>
</p:sldMaster>
"""

THEME = """<?xml version="1.0" encoding="UTF-8" standalone="yes"?>
<a:theme xmlns:a="http://schemas.openxmlformats.org/drawingml/2006/main" name="RV32I CNN Theme">
  <a:themeElements>
    <a:clrScheme name="Custom"><a:dk1><a:srgbClr val="101828"/></a:dk1><a:lt1><a:srgbClr val="FFFFFF"/></a:lt1><a:dk2><a:srgbClr val="344054"/></a:dk2><a:lt2><a:srgbClr val="F7F8FA"/></a:lt2><a:accent1><a:srgbClr val="175CD3"/></a:accent1><a:accent2><a:srgbClr val="039855"/></a:accent2><a:accent3><a:srgbClr val="F79009"/></a:accent3><a:accent4><a:srgbClr val="C11574"/></a:accent4><a:accent5><a:srgbClr val="667085"/></a:accent5><a:accent6><a:srgbClr val="101828"/></a:accent6><a:hlink><a:srgbClr val="175CD3"/></a:hlink><a:folHlink><a:srgbClr val="6941C6"/></a:folHlink></a:clrScheme>
    <a:fontScheme name="Custom"><a:majorFont><a:latin typeface="Microsoft YaHei"/><a:ea typeface="Microsoft YaHei"/></a:majorFont><a:minorFont><a:latin typeface="Microsoft YaHei"/><a:ea typeface="Microsoft YaHei"/></a:minorFont></a:fontScheme>
    <a:fmtScheme name="Custom"><a:fillStyleLst><a:solidFill><a:schemeClr val="phClr"/></a:solidFill></a:fillStyleLst><a:lnStyleLst><a:ln w="9525"><a:solidFill><a:schemeClr val="phClr"/></a:solidFill></a:ln></a:lnStyleLst><a:effectStyleLst><a:effectStyle/></a:effectStyleLst><a:bgFillStyleLst><a:solidFill><a:schemeClr val="phClr"/></a:solidFill></a:bgFillStyleLst></a:fmtScheme>
  </a:themeElements>
</a:theme>
"""


def write_pptx() -> None:
    slides = [
        slide_cover(),
        slide_problem(),
        slide_architecture(),
        slide_dataflow(),
        slide_verification(),
        slide_results(),
    ]
    OUT.parent.mkdir(parents=True, exist_ok=True)
    CHECK.parent.mkdir(parents=True, exist_ok=True)
    with zipfile.ZipFile(OUT, "w", zipfile.ZIP_DEFLATED) as zf:
        zf.writestr("[Content_Types].xml", content_types(len(slides)))
        zf.writestr("_rels/.rels", """<?xml version="1.0" encoding="UTF-8" standalone="yes"?><Relationships xmlns="http://schemas.openxmlformats.org/package/2006/relationships"><Relationship Id="rId1" Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/officeDocument" Target="ppt/presentation.xml"/><Relationship Id="rId2" Type="http://schemas.openxmlformats.org/package/2006/relationships/metadata/core-properties" Target="docProps/core.xml"/><Relationship Id="rId3" Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/extended-properties" Target="docProps/app.xml"/></Relationships>""")
        zf.writestr("docProps/core.xml", """<?xml version="1.0" encoding="UTF-8" standalone="yes"?><cp:coreProperties xmlns:cp="http://schemas.openxmlformats.org/package/2006/metadata/core-properties" xmlns:dc="http://purl.org/dc/elements/1.1/" xmlns:dcterms="http://purl.org/dc/terms/" xmlns:dcmitype="http://purl.org/dc/dcmitype/" xmlns:xsi="http://www.w3.org/2001/XMLSchema-instance"><dc:title>RV32I int8 CNN Accelerator Project</dc:title><dc:creator>Codex</dc:creator><cp:lastModifiedBy>Codex</cp:lastModifiedBy></cp:coreProperties>""")
        zf.writestr("docProps/app.xml", f"""<?xml version="1.0" encoding="UTF-8" standalone="yes"?><Properties xmlns="http://schemas.openxmlformats.org/officeDocument/2006/extended-properties" xmlns:vt="http://schemas.openxmlformats.org/officeDocument/2006/docPropsVTypes"><Application>Codex OpenXML Generator</Application><PresentationFormat>On-screen Show (16:9)</PresentationFormat><Slides>{len(slides)}</Slides></Properties>""")
        zf.writestr("ppt/presentation.xml", presentation_xml(len(slides)))
        zf.writestr("ppt/_rels/presentation.xml.rels", presentation_rels(len(slides)))
        zf.writestr("ppt/slideMasters/slideMaster1.xml", SLIDE_MASTER)
        zf.writestr("ppt/slideMasters/_rels/slideMaster1.xml.rels", """<?xml version="1.0" encoding="UTF-8" standalone="yes"?><Relationships xmlns="http://schemas.openxmlformats.org/package/2006/relationships"><Relationship Id="rId1" Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/slideLayout" Target="../slideLayouts/slideLayout1.xml"/><Relationship Id="rId2" Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/theme" Target="../theme/theme1.xml"/></Relationships>""")
        zf.writestr("ppt/slideLayouts/slideLayout1.xml", SLIDE_LAYOUT)
        zf.writestr("ppt/slideLayouts/_rels/slideLayout1.xml.rels", """<?xml version="1.0" encoding="UTF-8" standalone="yes"?><Relationships xmlns="http://schemas.openxmlformats.org/package/2006/relationships"><Relationship Id="rId1" Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/slideMaster" Target="../slideMasters/slideMaster1.xml"/></Relationships>""")
        zf.writestr("ppt/theme/theme1.xml", THEME)
        for i, slide in enumerate(slides, 1):
            zf.writestr(f"ppt/slides/slide{i}.xml", slide.xml())
            zf.writestr(f"ppt/slides/_rels/slide{i}.xml.rels", """<?xml version="1.0" encoding="UTF-8" standalone="yes"?><Relationships xmlns="http://schemas.openxmlformats.org/package/2006/relationships"><Relationship Id="rId1" Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/slideLayout" Target="../slideLayouts/slideLayout1.xml"/></Relationships>""")

    with zipfile.ZipFile(OUT, "r") as zf:
        names = zf.namelist()
        slide_files = [n for n in names if n.startswith("ppt/slides/slide") and n.endswith(".xml")]
        status = "PASS" if len(slide_files) == 6 and "ppt/presentation.xml" in names else "FAIL"
    CHECK.write_text(
        f"pptx={OUT}\nslide_count={len(slide_files)}\nopenxml_package_check={status}\n",
        encoding="utf-8",
    )
    print(CHECK.read_text(encoding="utf-8"))


if __name__ == "__main__":
    write_pptx()

