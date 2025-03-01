import httpclient
import htmlparser
import streams
import xmltree
import nimquery
import strutils
import strformat
import sugar
import tables
import nre
import sequtils

type
  FlagValue = enum
    NO_CHANGE,
    CHANGE,
    FORCE_TRUE,
    FORCE_FALSE,

  Flags = object
    zero: FlagValue
    subtract: FlagValue
    half_carry: FlagValue
    carry: FlagValue

  OpsCode = object
    code: string
    name: string
    args: seq[string]
    bytes: int
    cycles: seq[int]
    flags: Flags

  OpsCodeList = seq[OpsCode]

  ArgsTable = Table[string, seq[seq[string]]]


let url = "https://www.pastraiser.com/cpu/gameboy/gameboy_opcodes.html"


proc flag_value(v: string): FlagValue =
  if v == "1":
    return FlagValue.FORCE_TRUE
  elif v == "0":
    return FlagValue.FORCE_FALSE
  elif v == "-":
    return FlagValue.NO_CHANGE
  else:
    return FlagValue.CHANGE


proc extract_operations(trs: seq[XmlNode]): OpsCodeList =
  var operations = newSeq[OpsCode]()
  for i, tr in trs:
    if i == 0:
      continue
    let tds = tr.querySelectorAll("td")
    for j, td in tds:
      if j == 0:
        continue
      let code = ((i - 1) shl 4) + (j - 1)

      var children = collect(newSeq):
        for c in td.items(): c.innerText

      if children.len != 8:
        continue

      let names = children[0].split(" ")
      let name = names[0]
      let raw_args = if names.len == 1: @[] else: names[1].split(",")
      let bytes = children[2]
      let cycles = collect(newSeq):
        for c in children[5].split("/"): c.parseInt
      let raw_flags = children[7].split(" ")
      let flags = Flags(
        zero: flag_value(raw_flags[0]),
        subtract: flag_value(raw_flags[1]),
        half_carry: flag_value(raw_flags[2]),
        carry: flag_value(raw_flags[3]),
      )

      # (HL) => Indirect_HL とかにする。
      var args = newSeq[string]()
      for a in raw_args:
        if a == "(HL+)":
          args.add("Indirect_HLI")
        elif a == "(HL-)":
          args.add("Indirect_HLD")
        elif a.startsWith("("):
          args.add("Indirect_" & a.replace("(", "").replace(")", ""))
        elif a.match(re"^\d.*").isSome:
          args.add("_" & a)
        elif a == "SP+r8":
          args.add("SP_r8")
        else:
          args.add(a)

      operations.add(OpsCode(
        code: fmt"{code:#04X}",
        name: name,
        args: args,
        bytes: bytes.parseInt,
        cycles: cycles,
        flags: flags
      ))
  return operations


proc grouping_args(operations: OpsCodeList): ArgsTable =
  # 命令ごとにgroup
  var op_group = initTable[string, seq[OpsCode]]()
  for op in operations:
    if not op_group.hasKey(op.name):
      op_group[op.name] = newSeq[OpsCode]()
    op_group[op.name].add(op)

  # 各命令の引数をgroup (LD A, A  LD B, C) => [[A, B], [A, C]]
  var op_args = initTable[string, seq[seq[string]]]()
  for name, ops in op_group:
    let lengths = collect(newSeq):
      for op in ops: op.args.len
    let max_length = max(lengths)
    let min_length = min(lengths)
    var arg_group_list = newSeq[seq[string]](max_length)
    if max_length != min_length:
      arg_group_list[max_length - 1].add("NONE")
    for op in ops:
      for i, a in op.args:
        if not arg_group_list[i].contains(a):
          arg_group_list[i].add(a)
    op_args[name] = arg_group_list
  return op_args


proc writeEnums(f: File, op_args: ArgsTable) =

  # enum ArithmeticTarget { ...
  for name, args in op_args:
    for i, list in args:
      f.writeLine fmt"pub enum {name}_Arg_{i}" & "{"
      for v in list:
        f.writeLine fmt"    {v},"
      f.writeLine "}\n"

  # enum Instruction {
  f.writeLine "pub enum Instruction {"
  for name, args in op_args:
    let arg_str = collect(newSeq):
      for i, a in args: fmt"{name}_Arg_{i}"
    let a = arg_str.join(", ")
    f.writeLine fmt"    {name}({a}),"
  f.writeLine "}\n"


proc writeFromByteFunction(f: File, operations: OpsCodeList, op_args: ArgsTable, func_name: string) =
  f.writeLine fmt"pub fn {func_name}(byte: u8) -> Option<Instruction> " & "{"
  f.writeLine "    match byte {"
  for op in operations:
    var args = newSeq[string]()
    for i, a in op_args[op.name]:
      if op.args.len <= i:
        args.add(fmt"{op.name}_Arg_{i}::NONE")
      else:
        let v = op.args[i]
        args.add(fmt"{op.name}_Arg_{i}::{v}")
    let a = args.join(", ")
    f.writeLine(fmt"        {op.code} => Some(Instruction::{op.name}({a})),")
  f.writeLine("        _ => None,")
  f.writeLine "    }"
  f.writeLine "}\n"


proc writeByteTable(f: File, np_prefixed: OpsCodeList, prefixed: OpsCodeList, func_name: string) =
  f.writeLine fmt"pub fn {func_name}(byte: u8, prefiexed: bool) -> u16 " & "{"
  f.writeLine "    match prefiexed {"
  f.writeLine "        true => {"
  f.writeLine "            match byte {"
  for op in np_prefixed:
    f.writeLine(fmt"                {op.code} => {op.bytes},")
  f.writeLine(fmt"                _ => 0,")
  f.writeLine "            }"
  f.writeLine "        },"
  f.writeLine "        false => {"
  f.writeLine "            match byte {"
  for op in prefixed:
    f.writeLine(fmt"                {op.code} => {op.bytes},")
  f.writeLine(fmt"                _ => 0,")
  f.writeLine "            }"
  f.writeLine "        }"
  f.writeLine "    }"
  f.writeLine "}\n"

proc main() =
  let client = newHttpClient()
  let response = client.get(url)
  let html = response.body.newStringStream().parseHtml()

  let ts = html.querySelectorAll("table")

  let no_prefixed_ops = extract_operations(ts[0].querySelectorAll("tr"))
  let prefixed_ops = extract_operations(ts[1].querySelectorAll("tr"))

  let all_ops = concat(no_prefixed_ops, prefixed_ops)
  let args = grouping_args(all_ops)

  var f = open("instruction.rs", FileMode.fmWrite)
  defer:
    close(f)
  writeEnums(f, args)
  writeFromByteFunction(f, no_prefixed_ops, args, "from_byte_not_prefixed")
  writeFromByteFunction(f, prefixed_ops, args, "from_byte_prefixed")

  writeByteTable(f, no_prefixed_ops, prefixed_ops, "instruction_bytes")

  # fn jump(&self, arg0: instruction::JP_Arg_0, arg1: instruction::JP_Arg_1) -> u16 {
  for name, op_args in args:
    var list = newSeq[string]()
    for i, a in op_args:
      list.add(fmt"arg{i}: instruction::{name}_Arg_{i}")
    let a = list.join(", ")
    echo(fmt"fn {name.toLowerAscii}(&mut self, {a}) " & "{}")

  echo "\n"

  echo "fn execute(&mut self, instruction: instruction::Instruction) -> u16 {"
  echo "    match instruction {"
  for name, op_args in args:
    var list = newSeq[string]()
    for i, a in op_args:
      list.add(fmt"arg{i}")
    let a = list.join(", ")
    echo fmt"        instruction::Instruction::{name}({a}) => self.{name.toLowerAscii}({a}),"
  echo "    }"
  echo "}"
main()
