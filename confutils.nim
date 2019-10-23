import
  std/[options, strutils, wordwrap],
  stew/shims/macros,
  confutils/[defs, cli_parser]

export
  defs

const
  useBufferedOutput = defined(nimscript)
  noColors = useBufferedOutput or defined(confutils_no_colors)
  descriptionPadding = 6
  minLongformsWidth =  24 - descriptionPadding

when not defined(nimscript):
  import
    os, terminal,
    confutils/shell_completion

type
  HelpAppInfo = ref object
    appInvocation: string
    helpBanner: string
    hasShortforms: bool
    maxLongformLen: int
    terminalWidth: int
    longformsWidth: int

  CmdInfo = ref object
    name: string
    opts: seq[OptInfo]
    shortHelpString: string

  OptKind = enum
    Discriminator
    CliSwitch
    Arg

  OptInfo = ref object
    longform, shortform, desc, typename: string
    idx: int
    hasDefault: bool
    case kind: OptKind
    of Discriminator:
      isCommand: bool
      isImplicitlySelectable: bool
      subCmds: seq[CmdInfo]
      defaultSubCmd: int
    else:
      discard

  FieldSetter[Configuration] = proc (cfg: var Configuration, val: TaintedString) {.nimcall, gcsafe.}
  FieldCompleter = proc (val: TaintedString): seq[string] {.nimcall, gcsafe.}

proc newLit*(arg: ref): NimNode {.compileTime.} =
  result = nnkObjConstr.newTree(arg.type.getTypeInst[1])
  for a, b in fieldPairs(arg[]):
    result.add nnkExprColonExpr.newTree(newIdentNode(a), newLit(b))

proc getFieldName(caseField: NimNode): NimNode =
  result = caseField
  if result.kind == nnkIdentDefs: result = result[0]
  if result.kind == nnkPragmaExpr: result = result[0]
  if result.kind == nnkPostfix: result = result[1]

when defined(nimscript):
  proc appInvocation: string =
    "nim " & (if paramCount() > 1: paramStr(1) else: "<nims-script>")

  type stderr = object

  template writeLine(T: type stderr, msg: string) =
    echo msg

  proc commandLineParams(): seq[string] =
    for i in 2 .. paramCount():
      result.add paramStr(i)

  # TODO: Why isn't this available in NimScript?
  proc getCurrentExceptionMsg(): string =
    ""

  template terminalWidth: int =
    100000

else:
  template appInvocation: string =
    getAppFilename().splitFile.name

when noColors:
  const
    styleBright = ""
    fgYellow = ""
    fgWhite = ""
    fgGreen = ""
    fgCyan = ""
    fgBlue = ""

when useBufferedOutput:
  template helpOutput(args: varargs[string]) =
    for arg in args:
      help.add arg

  template flushHelp =
    echo help

else:
  template helpOutput(args: varargs[untyped]) =
    stdout.styledWrite args

  template flushHelp =
    discard

const
  fgSection = fgYellow
  fgCommand = fgCyan
  fgOption = fgBlue
  fgValue = fgGreen
  fgType = fgYellow

func isCliSwitch(opt: OptInfo): bool =
  opt.kind == CliSwitch or
  (opt.kind == Discriminator and opt.isCommand == false)

func hasOpts(cmd: CmdInfo): bool =
  cmd.opts.len > 0 and cmd.opts[0].isCliSwitch

func hasArgs(cmd: CmdInfo): bool =
  cmd.opts.len > 0 and cmd.opts[^1].kind == Arg

func firstArgIdx(cmd: CmdInfo): int =
  # This will work correctly only if the command has arguments.
  result = cmd.opts.len - 1
  while result > 0:
    if cmd.opts[result - 1].kind != Arg:
      return

iterator args(cmd: CmdInfo): OptInfo =
  if cmd.hasArgs:
    for i in cmd.firstArgIdx ..< cmd.opts.len:
      yield cmd.opts[i]

func getSubCmdDiscriminator(cmd: CmdInfo): OptInfo =
  for i in countdown(cmd.opts.len - 1, 0):
    let opt = cmd.opts[i]
    if opt.kind != Arg:
      if opt.kind == Discriminator and opt.isCommand:
        return opt
      else:
        return nil

template hasSubCommands(cmd: CmdInfo): bool =
  getSubCmdDiscriminator(cmd) != nil

iterator subCmds(cmd: CmdInfo): CmdInfo =
  let subCmdDiscriminator = cmd.getSubCmdDiscriminator
  if subCmdDiscriminator != nil:
    for cmd in subCmdDiscriminator.subCmds:
      yield cmd

proc getDefaultSubCmd(cmd: CmdInfo): CmdInfo =
  let subCmdDiscriminator = cmd.getSubCmdDiscriminator
  if subCmdDiscriminator != nil and subCmdDiscriminator.defaultSubCmd != -1:
    return subCmdDiscriminator.subCmds[subCmdDiscriminator.defaultSubCmd]

template isSubCommand(cmd: CmdInfo): bool =
  cmd.name.len > 0

func maxLongformLen(cmd: CmdInfo): int =
  result = 0
  for opt in cmd.opts:
    if opt.kind == Arg or opt.kind == Discriminator and opt.isCommand:
      continue
    result = max(result, opt.longform.len)
    if opt.kind == Discriminator:
      for subCmd in opt.subCmds:
        result = max(result, subCmd.maxLongformLen)

func hasShortforms(cmd: CmdInfo): bool =
  for opt in cmd.opts:
    if opt.kind == Arg or opt.kind == Discriminator and opt.isCommand:
      continue
    if opt.shortform.len > 0:
      return true
    if opt.kind == Discriminator:
      for subCmd in opt.subCmds:
        if hasShortforms(subCmd):
          return true

func humaneName(opt: OptInfo): string =
  if opt.longform.len > 0: opt.longform
  else: opt.shortform

template padding(output: string, desiredWidth: int): string =
  spaces(max(desiredWidth - output.len, 0))

proc writeDesc(help: var string, appInfo: HelpAppInfo, desc: string) =
  let
    nonDescColumns = (6 + appInfo.longformsWidth)
    remainingColumns = appInfo.terminalWidth - nonDescColumns

  if remainingColumns < 36:
    helpOutput "\p ", wrapWords(desc, appInfo.terminalWidth - 1,
                                newLine = "\p ")
  else:
    helpOutput wrapWords(desc, remainingColumns,
                         newLine = "\p" & spaces(nonDescColumns))

proc describeInvocation(help: var string,
                        cmd: CmdInfo, cmdInvocation: string,
                        appInfo: HelpAppInfo) =
  helpOutput styleBright, "\p", fgCommand, cmdInvocation
  var longestArg = 0

  if cmd.opts.len > 0:
    if cmd.hasOpts: helpOutput " [OPTIONS]..."

    let subCmdDiscriminator = cmd.getSubCmdDiscriminator
    if subCmdDiscriminator != nil: helpOutput " command"

    for arg in cmd.args:
      helpOutput " <", arg.longform, ">"
      longestArg = max(longestArg, arg.longform.len)

  helpOutput "\p"

  for arg in cmd.args:
    if arg.desc.len > 0:
      let cliArg = "<" & arg.humaneName & ">"
      helpOutput cliArg, padding(cliArg, 6 + appInfo.longformsWidth)
      help.writeDesc appInfo, arg.desc

proc describeOptions(help: var string,
                     cmd: CmdInfo, cmdInvocation: string,
                     appInfo: HelpAppInfo, isSubOptions = false) =
  if cmd.hasOpts:
    if isSubOptions:
      helpOutput ", the following additional options are available:\p\p"
    else:
      helpOutput "\pThe following options are available:\p\p"

    for opt in cmd.opts:
      if opt.kind == Arg: continue
      if opt.kind == Discriminator:
        if opt.isCommand: continue

      # Indent all command-line switches
      helpOutput " "

      if opt.shortform.len > 0:
        helpOutput fgOption, styleBright, "-", opt.shortform, ", "
      elif appInfo.hasShortforms:
        # Add additional indentatition, so all longforms are aligned
        helpOutput "    "

      if opt.longform.len > 0:
        let switch = "--" & opt.longform
        helpOutput fgOption, styleBright,
                   switch, padding(switch, appInfo.longformsWidth)
      else:
        helpOutput spaces(2 + appInfo.longformsWidth)

      if opt.desc.len > 0:
        help.writeDesc appInfo, opt.desc.replace("%t", opt.typename)

      helpOutput "\p"

      if opt.kind == Discriminator:
        for i, subCmd in opt.subCmds:
          if not subCmd.hasOpts: continue

          helpOutput "\pWhen ", styleBright, fgBlue, opt.humaneName, fgWhite, " = ", fgGreen, subCmd.name

          if i == opt.defaultSubCmd: helpOutput " (default)"
          help.describeOptions subCmd, cmdInvocation, appInfo, isSubOptions = true

  let subCmdDiscriminator = cmd.getSubCmdDiscriminator
  if subCmdDiscriminator != nil:
    let defaultCmdIdx = subCmdDiscriminator.defaultSubCmd
    if defaultCmdIdx != -1:
      let defaultCmd = subCmdDiscriminator.subCmds[defaultCmdIdx]
      help.describeOptions defaultCmd, cmdInvocation, appInfo

    helpOutput fgSection, "\pAvailable sub-commands:\p"

    for i, subCmd in subCmdDiscriminator.subCmds:
      if i != subCmdDiscriminator.defaultSubCmd:
        let subCmdInvocation = cmdInvocation & " " & subCmd.name
        help.describeInvocation subCmd, subCmdInvocation, appInfo
        help.describeOptions subCmd, subCmdInvocation, appInfo

proc showHelp(appInfo: HelpAppInfo, activeCmds: openarray[CmdInfo]) =
  var help = ""
  helpOutput appInfo.helpBanner

  let cmd = activeCmds[^1]

  appInfo.maxLongformLen = cmd.maxLongformLen
  appInfo.hasShortforms = cmd.hasShortforms
  appInfo.terminalWidth = terminalWidth()
  appInfo.longformsWidth = min(minLongformsWidth, appInfo.maxLongformLen) +
                           descriptionPadding

  var cmdInvocation = appInfo.appInvocation
  for i in 1 ..< activeCmds.len:
    cmdInvocation.add " "
    cmdInvocation.add activeCmds[i].name

  # Write out the app or script name
  helpOutput fgSection, "Usage: \p"
  help.describeInvocation cmd, cmdInvocation, appInfo
  help.describeOptions cmd, cmdInvocation, appInfo
  helpOutput "\p"

  flushHelp
  quit 1

func getNextArgIdx(cmd: CmdInfo, consumedArgIdx: int): int =
  for i in consumedArgIdx + 1 ..< cmd.opts.len:
    if cmd.opts[i].kind == Arg:
      return i

  return -1

proc noMoreArgsError(cmd: CmdInfo): string =
  result = if cmd.isSubCommand: "The command '$1'" % [cmd.name]
           else: appInvocation()
  result.add " does not accept"
  if cmd.hasArgs: result.add " additional"
  result.add " arguments"

proc findOpt(opts: openarray[OptInfo], name: string): OptInfo =
  for opt in opts:
    if cmpIgnoreStyle(opt.longform, name) == 0 or
       cmpIgnoreStyle(opt.shortform, name) == 0:
      return opt

proc findOpt(activeCmds: openarray[CmdInfo], name: string): OptInfo =
  for i in countdown(activeCmds.len - 1, 0):
    let found = findOpt(activeCmds[i].opts, name)
    if found != nil: return found

proc findCmd(cmds: openarray[CmdInfo], name: string): CmdInfo =
  for cmd in cmds:
    if cmpIgnoreStyle(cmd.name, name) == 0:
      return cmd

proc findSubCmd(cmd: CmdInfo, name: string): CmdInfo =
  let subCmdDiscriminator = cmd.getSubCmdDiscriminator
  if subCmdDiscriminator != nil:
    let cmd = findCmd(subCmdDiscriminator.subCmds, name)
    if cmd != nil: return cmd

  return nil

proc startsWithIgnoreStyle(s: string, prefix: string): bool =
  # Similar in spirit to cmpIgnoreStyle, but compare only the prefix.
  var i = 0
  var j = 0

  while true:
    # Skip any underscore
    while i < s.len and s[i] == '_': inc i
    while j < prefix.len and prefix[j] == '_': inc j

    if j == prefix.len:
      # The whole prefix matches
      return true
    elif i == s.len:
      # We've reached the end of `s` without matching the prefix
      return false
    elif toLowerAscii(s[i]) != toLowerAscii(prefix[j]):
      return false

    inc i
    inc j

when defined(debugCmdTree):
  proc printCmdTree(cmd: CmdInfo, indent = 0) =
    let blanks = spaces(indent)
    echo blanks, "> ", cmd.name

    for opt in cmd.opts:
      if opt.kind == Discriminator:
        for subcmd in opt.subCmds:
          printCmdTree(subcmd, indent + 2)
      else:
        echo blanks, "  - ", opt.longform, ": ", opt.typename

else:
  template printCmdTree(cmd: CmdInfo) = discard

# TODO remove the overloads here to get better "missing overload" error message
proc parseCmdArg*(T: type InputDir, p: TaintedString): T =
  if not dirExists(p.string):
    raise newException(ValueError, "Directory doesn't exist")

  result = T(p)

proc parseCmdArg*(T: type InputFile, p: TaintedString): T =
  # TODO this is needed only because InputFile cannot be made
  # an alias of TypedInputFile at the moment, because of a generics
  # caching issue
  if not fileExists(p.string):
    raise newException(ValueError, "File doesn't exist")

  when not defined(nimscript):
    try:
      let f = open(p.string, fmRead)
      close f
    except IOError:
      raise newException(ValueError, "File not accessible")

  result = T(p.string)

proc parseCmdArg*(T: type TypedInputFile, p: TaintedString): T =
  var path = p.string
  when T.defaultExt.len > 0:
    path = path.addFileExt(T.defaultExt)

  if not fileExists(path):
    raise newException(ValueError, "File doesn't exist")

  when not defined(nimscript):
    try:
      let f = open(path, fmRead)
      close f
    except IOError:
      raise newException(ValueError, "File not accessible")

  result = T(path)

proc parseCmdArg*(T: type[OutDir|OutFile|OutPath], p: TaintedString): T =
  result = T(p)

proc parseCmdArg*[T](_: type Option[T], s: TaintedString): Option[T] =
  return some(parseCmdArg(T, s))

template parseCmdArg*(T: type string, s: TaintedString): string =
  string s

proc parseCmdArg*(T: type SomeSignedInt, s: TaintedString): T =
  T parseInt(string s)

proc parseCmdArg*(T: type SomeUnsignedInt, s: TaintedString): T =
  T parseUInt(string s)

proc parseCmdArg*(T: type SomeFloat, p: TaintedString): T =
  result = parseFloat(p)

proc parseCmdArg*(T: type bool, p: TaintedString): T =
  result = parseBool(p)

proc parseCmdArg*(T: type enum, s: TaintedString): T =
  parseEnum[T](string(s))

proc parseCmdArgAux(T: type, s: TaintedString): T = # {.raises: [ValueError].} =
  # The parseCmdArg procs are allowed to raise only `ValueError`.
  # If you have provided your own specializations, please handle
  # all other exception types.
  mixin parseCmdArg
  parseCmdArg(T, s)

proc completeCmdArg(T: type enum, val: TaintedString): seq[string] =
  for e in low(T)..high(T):
    let as_str = $e
    if startsWithIgnoreStyle(as_str, val):
      result.add($e)

proc completeCmdArg(T: type SomeNumber, val: TaintedString): seq[string] =
  return @[]

proc completeCmdArg(T: type bool, val: TaintedString): seq[string] =
  return @[]

proc completeCmdArg(T: type string, val: TaintedString): seq[string] =
  return @[]

proc completeCmdArg*(T: type[InputFile|TypedInputFile|InputDir|OutFile|OutDir|OutPath],
                     val: TaintedString): seq[string] =
  when not defined(nimscript):
    let (dir, name, ext) = splitFile(val)
    let tail = name & ext
    # Expand the directory component for the directory walker routine
    let dir_path = if dir == "": "." else: expandTilde(dir)
    # Dotfiles are hidden unless the user entered a dot as prefix
    let show_dotfiles = len(name) > 0 and name[0] == '.'

    for kind, path in walkDir(dir_path, relative=true):
      if not show_dotfiles and path[0] == '.':
        continue

      # Do not show files if asked for directories, on the other hand we must show
      # directories even if a file is requested to allow the user to select a file
      # inside those
      if type(T) is (InputDir or OutDir) and kind notin {pcDir, pcLinkToDir}:
        continue

      # Note, no normalization is needed here
      if path.startsWith(tail):
        var match = dir_path / path
        # Add a trailing slash so that completions can be chained
        if kind in {pcDir, pcLinkToDir}:
          match &= DirSep

        result.add(shellPathEscape(match))

proc completeCmdArg[T](_: type seq[T], val: TaintedString): seq[string] =
  return @[]

proc completeCmdArg[T](_: type Option[T], val: TaintedString): seq[string] =
  return completeCmdArg(type(T), val)

proc completeCmdArgAux(T: type, val: TaintedString): seq[string] =
  return completeCmdArg(T, val)

template setField[T](loc: var T, val: TaintedString, defaultVal: untyped) =
  type FieldType = type(loc)
  loc = if len(val) > 0: parseCmdArgAux(FieldType, val)
        else: FieldType(defaultVal)

template setField[T](loc: var seq[T], val: TaintedString, defaultVal: untyped) =
  loc.add parseCmdArgAux(type(loc[0]), val)

template simpleSet(loc: var auto) =
  discard

proc makeDefaultValue*(T: type): T =
  discard

proc requiresInput*(T: type): bool =
  not ((T is seq) or (T is Option))

proc acceptsMultipleValues*(T: type): bool =
  T is seq

template debugMacroResult(macroName: string) {.dirty.} =
  when defined(debugMacros) or defined(debugConfutils):
    echo "\n-------- ", macroName, " ----------------------"
    echo result.repr

macro generateFieldSetters(RecordType: type): untyped =
  var recordDef = RecordType.getType[1].getImpl
  let makeDefaultValue = bindSym"makeDefaultValue"

  result = newTree(nnkStmtListExpr)
  var settersArray = newTree(nnkBracket)

  for field in recordFields(recordDef):
    var
      setterName = ident($field.name & "Setter")
      fieldName = field.name
      configVar = ident "config"
      configField = newTree(nnkDotExpr, configVar, fieldName)
      defaultValue = field.readPragma"defaultValue"
      completerName = ident($field.name & "Complete")

    if defaultValue == nil:
      defaultValue = newCall(makeDefaultValue, newTree(nnkTypeOfExpr, configField))

    # TODO: This shouldn't be necessary. The type symbol returned from Nim should
    # be typed as a tyTypeDesc[tyString] instead of just `tyString`. To be filed.
    var fixedFieldType = newTree(nnkTypeOfExpr, field.typ)

    settersArray.add newTree(nnkTupleConstr,
                             newLit($fieldName),
                             setterName, completerName,
                             newCall(bindSym"requiresInput", fixedFieldType),
                             newCall(bindSym"acceptsMultipleValues", fixedFieldType))

    result.add quote do:
      proc `completerName`(val: TaintedString): seq[string] {.nimcall, gcsafe.} =
        return completeCmdArgAux(`fixedFieldType`, val)

      proc `setterName`(`configVar`: var `RecordType`, val: TaintedString) {.nimcall, gcsafe.} =
        when `configField` is enum:
          # TODO: For some reason, the normal `setField` rejects enum fields
          # when they are used as case discriminators. File this as a bug.
          if len(val) > 0:
            `configField` = parseEnum[type(`configField`)](string(val))
          else:
            `configField` = `defaultValue`
        else:
          setField(`configField`, val, `defaultValue`)

  result.add settersArray
  debugMacroResult "Field Setters"

macro buildCommandTree(RecordType: type): untyped =
  var
    recordDef = RecordType.getType[1].getImpl
    res = CmdInfo()
    discriminatorFields = newSeq[OptInfo]()
    fieldIdx = 0

  for field in recordFields(recordDef):
    let
      isImplicitlySelectable = field.readPragma"implicitlySelectable" != nil
      defaultValue = field.readPragma"defaultValue"
      shortform = field.readPragma"shortform"
      longform = field.readPragma"longform"
      desc = field.readPragma"desc"

    var opt = OptInfo(kind: if field.isDiscriminator: Discriminator else: CliSwitch,
                      idx: fieldIdx,
                      longform: $field.name,
                      hasDefault: defaultValue != nil,
                      typename: field.typ.repr)

    if desc != nil: opt.desc = desc.strVal
    if longform != nil: opt.longform = longform.strVal
    if shortform != nil: opt.shortform = shortform.strVal

    inc fieldIdx

    if field.isDiscriminator:
      discriminatorFields.add opt
      let cmdType = field.typ.getImpl[^1]
      if cmdType.kind != nnkEnumTy:
        error "Only enums are supported as case object discriminators", field.name

      opt.isImplicitlySelectable = field.readPragma"implicitlySelectable" != nil
      opt.isCommand = field.readPragma"command" != nil

      for i in 1 ..< cmdType.len:
        let name = $cmdType[i]
        if defaultValue != nil and eqIdent(name, defaultValue):
          opt.defaultSubCmd = i - 1
        opt.subCmds.add CmdInfo(name: name)

      if defaultValue == nil:
        opt.defaultSubCmd = -1
      else:
        if opt.defaultSubCmd == -1:
          error "The default value is not a valid enum value", defaultValue

    if field.caseField != nil and field.caseBranch != nil:
      let fieldName = field.caseField.getFieldName
      var discriminator = findOpt(discriminatorFields, $fieldName)
      if discriminator == nil:
        error "Unable to find " & $fieldName
      let branchEnumVal = field.caseBranch[0]
      var cmd = findCmd(discriminator.subCmds, $branchEnumVal)
      cmd.opts.add opt
    else:
      res.opts.add opt

  result = newLit(res)
  debugMacroResult "Command Tree"

proc load*(Configuration: type,
           cmdLine = commandLineParams(),
           version = "",
           printUsage = true,
           quitOnFailure = true): Configuration =
  ## Loads a program configuration by parsing command-line arguments
  ## and a standard set of config files that can specify:
  ##
  ##  - working directory settings
  ##  - user settings
  ##  - system-wide setttings
  ##
  ##  Supports multiple config files format (INI/TOML, YAML, JSON).

  # This is an initial naive implementation that will be improved
  # over time.

  let fieldSetters = generateFieldSetters(Configuration)
  var fieldCounters: array[fieldSetters.len, int]

  var rootCmd = buildCommandTree(Configuration)
  printCmdTree rootCmd

  let confAddr = addr result
  var activeCmds = @[rootCmd]
  template lastCmd: auto = activeCmds[^1]
  var nextArgIdx = lastCmd.getNextArgIdx(-1)

  proc fail(msg: string) =
    if quitOnFailure:
      stderr.writeLine(msg)
      stderr.writeLine("Try '$1 --help' for more information" % appInvocation())
      quit 1
    else:
      raise newException(ConfigurationError, msg)

  template applySetter(setterIdx: int, cmdLineVal: TaintedString) =
    try:
      fieldSetters[setterIdx][1](confAddr[], cmdLineVal)
      inc fieldCounters[setterIdx]
    except:
      fail("Invalid value for " & fieldSetters[setterIdx][0] & ": " &
           getCurrentExceptionMsg())

  template getArgCompletions(opt: OptInfo, prefix: TaintedString): seq[string] =
    fieldSetters[opt.idx][2](prefix)

  template required(opt: OptInfo): bool =
    fieldSetters[opt.idx][3] and not opt.hasDefault

  template allowNextValue(opt: OptInfo): bool =
    fieldSetters[opt.idx][4] or fieldCounters[opt.idx] == 0

  proc processMissingOpts(conf: var Configuration, cmd: CmdInfo) =
    for opt in cmd.opts:
      if fieldCounters[opt.idx] == 0:
        if opt.required:
          fail "The required option '$1' was not specified" % [opt.longform]
        elif opt.hasDefault:
          fieldSetters[opt.idx][1](conf, TaintedString(""))

  template activateCmd(discriminator: OptInfo, activatedCmd: CmdInfo) =
    let cmd = activatedCmd
    applySetter(discriminator.idx, TaintedString(cmd.name))
    activeCmds.add cmd
    nextArgIdx = cmd.getNextArgIdx(-1)

  type
    ArgKindFilter = enum
      longForm
      shortForm

  when not defined(nimscript):
    proc showMatchingOptions(cmd: CmdInfo, prefix: string, filterKind: set[ArgKindFilter]) =
      var matchingOptions: seq[OptInfo]

      if len(prefix) > 0:
        # Filter the options according to the input prefix
        for opt in cmd.opts:
          if longForm in filterKind and len(opt.longform) > 0:
            if startsWithIgnoreStyle(opt.longform, prefix):
              matchingOptions.add(opt)
          if shortForm in filterKind and len(opt.shortform) > 0:
            if startsWithIgnoreStyle(opt.shortform, prefix):
              matchingOptions.add(opt)
      else:
        matchingOptions = cmd.opts

      for opt in matchingOptions:
        # The trailing '=' means the switch accepts an argument
        let trailing = if opt.typename != "bool": "=" else: ""

        if longForm in filterKind and len(opt.longform) > 0:
          stdout.writeLine("--", opt.longform, trailing)
        if shortForm in filterKind and len(opt.shortform) > 0:
          stdout.writeLine('-', opt.shortform, trailing)

    let completion = splitCompletionLine()
    # If we're not asked to complete a command line the result is an empty list
    if len(completion) != 0:
      var cmdStack = @[rootCmd]
      # Try to understand what the active chain of commands is without parsing the
      # whole command line
      for tok in completion[1..^1]:
        if not tok.startsWith('-'):
          let subCmd = findSubCmd(cmdStack[^1], string(tok))
          if subCmd != nil: cmdStack.add(subCmd)

      let cur_word = completion[^1]
      let prev_word = if len(completion) > 2: completion[^2] else: ""
      let prev_prev_word = if len(completion) > 3: completion[^3] else: ""

      if cur_word.startsWith('-'):
        # Show all the options matching the prefix input by the user
        let isLong = cur_word.startsWith("--")
        var option_word = cur_word
        option_word.removePrefix('-')

        for i in countdown(cmdStack.len - 1, 0):
          let argFilter =
            if isLong:
              {longForm}
            elif len(cur_word) > 1:
              # If the user entered a single hypen then we show both long & short
              # variants
              {shortForm}
            else:
              {longForm, shortForm}

          showMatchingOptions(cmdStack[i], option_word, argFilter)
      elif (prev_word.startsWith('-') or
          (prev_word == "=" and prev_prev_word.startsWith('-'))):
        # Handle cases where we want to complete a switch choice
        # -switch
        # -switch=
        var option_word = if len(prev_word) == 1: prev_prev_word else: prev_word
        option_word.removePrefix('-')

        let opt = findOpt(cmdStack, string(option_word))
        if opt != nil:
          for arg in getArgCompletions(opt, cur_word):
            stdout.writeLine(arg)
      elif cmdStack[^1].hasSubCommands:
        # Show all the available subcommands
        for subCmd in subCmds(cmdStack[^1]):
          if startsWithIgnoreStyle(subCmd.name, cur_word):
            stdout.writeLine(subCmd.name)
      else:
        # Full options listing
        for i in countdown(cmdStack.len - 1, 0):
          showMatchingOptions(cmdStack[i], "", {longForm, shortForm})

      stdout.flushFile()

      return

  proc lazyHelpAppInfo: HelpAppInfo =
    HelpAppInfo(appInvocation: appInvocation())

  for kind, key, val in getopt(cmdLine):
    let key = string(key)
    case kind
    of cmdLongOption, cmdShortOption:
      if cmpIgnoreStyle(key, "help") == 0:
        showHelp lazyHelpAppInfo(), activeCmds

      var opt = findOpt(activeCmds, key)
      if opt == nil:
        # We didn't find the option.
        # Check if it's from the default command and activate it if necessary:
        let subCmdDiscriminator = lastCmd.getSubCmdDiscriminator
        if subCmdDiscriminator != nil:
          if subCmdDiscriminator.defaultSubCmd != -1:
            let defaultCmd = subCmdDiscriminator.subCmds[subCmdDiscriminator.defaultSubCmd]
            opt = findOpt(defaultCmd.opts, key)
            if opt != nil:
              activateCmd(subCmdDiscriminator, defaultCmd)
          else:
            discard

      if opt != nil:
        if opt.allowNextValue:
          applySetter(opt.idx, val)
        else:
          fail "The options '$1' should not be specified more than once" % [key]
      else:
        fail "Unrecognized option '$1'" % [key]

    of cmdArgument:
      if cmpIgnoreStyle(key, "help") == 0 and lastCmd.hasSubCommands:
        showHelp lazyHelpAppInfo(), activeCmds

      block processArg:
        let subCmdDiscriminator = lastCmd.getSubCmdDiscriminator
        if subCmdDiscriminator != nil:
          let subCmd = findCmd(subCmdDiscriminator.subCmds, key)
          if subCmd != nil:
            activateCmd(subCmdDiscriminator, subCmd)
            break processArg

        if nextArgIdx == -1:
          fail lastCmd.noMoreArgsError

        applySetter(nextArgIdx, key)

        if not fieldSetters[nextArgIdx][4]:
          nextArgIdx = lastCmd.getNextArgIdx(nextArgIdx)

    else:
      discard

  let subCmdDiscriminator = lastCmd.getSubCmdDiscriminator
  if subCmdDiscriminator != nil and
     subCmdDiscriminator.defaultSubCmd != -1 and
     fieldCounters[subCmdDiscriminator.idx] == 0:
    let defaultCmd = subCmdDiscriminator.subCmds[subCmdDiscriminator.defaultSubCmd]
    activateCmd(subCmdDiscriminator, defaultCmd)

  for cmd in activeCmds:
    result.processMissingOpts(cmd)

proc defaults*(Configuration: type): Configuration =
  load(Configuration, cmdLine = @[], printUsage = false, quitOnFailure = false)

proc dispatchImpl(cliProcSym, cliArgs, loadArgs: NimNode): NimNode =
  # Here, we'll create a configuration object with fields matching
  # the CLI proc params. We'll also generate a call to the designated proc
  let configType = genSym(nskType, "CliConfig")
  let configFields = newTree(nnkRecList)
  let configVar = genSym(nskLet, "config")
  var dispatchCall = newCall(cliProcSym)

  # The return type of the proc is skipped over
  for i in 1 ..< cliArgs.len:
    var arg = copy cliArgs[i]

    # If an argument doesn't specify a type, we infer it from the default value
    if arg[1].kind == nnkEmpty:
      if arg[2].kind == nnkEmpty:
        error "Please provide either a default value or type of the parameter", arg
      arg[1] = newCall(bindSym"typeof", arg[2])

    # Turn any default parameters into the confutils's `defaultValue` pragma
    if arg[2].kind != nnkEmpty:
      if arg[0].kind != nnkPragmaExpr:
        arg[0] = newTree(nnkPragmaExpr, arg[0], newTree(nnkPragma))
      arg[0][1].add newColonExpr(bindSym"defaultValue", arg[2])
      arg[2] = newEmptyNode()

    configFields.add arg
    dispatchCall.add newTree(nnkDotExpr, configVar, skipPragma arg[0])

  let cliConfigType = nnkTypeSection.newTree(
    nnkTypeDef.newTree(
      configType,
      newEmptyNode(),
      nnkObjectTy.newTree(
        newEmptyNode(),
        newEmptyNode(),
        configFields)))

  var loadConfigCall = newCall(bindSym"load", configType)
  for p in loadArgs: loadConfigCall.add p

  result = quote do:
    `cliConfigType`
    let `configVar` = `loadConfigCall`
    `dispatchCall`

macro dispatch*(fn: typed, args: varargs[untyped]): untyped =
  if fn.kind != nnkSym or
     fn.symKind notin {nskProc, nskFunc, nskMacro, nskTemplate}:
    error "The first argument to `confutils.dispatch` should be a callable symbol"

  let fnImpl = fn.getImpl
  result = dispatchImpl(fnImpl.name, fnImpl.params, args)
  debugMacroResult "Dispatch Code"

macro cli*(args: varargs[untyped]): untyped =
  if args.len == 0:
    error "The cli macro expects a do block", args

  let doBlock = args[^1]
  if doBlock.kind notin {nnkDo, nnkLambda}:
    error "The last argument to `confutils.cli` should be a do block", doBlock

  args.del(args.len - 1)

  # Create a new anonymous proc we'll dispatch to
  let cliProcName = genSym(nskProc, "CLI")
  var cliProc = newTree(nnkProcDef, cliProcName)
  # Copy everything but the name from the do block:
  for i in 1 ..< doBlock.len: cliProc.add doBlock[i]

  # Generate the final code
  result = newStmtList(cliProc, dispatchImpl(cliProcName, cliProc.params, args))

  # TODO: remove this once Nim supports custom pragmas on proc params
  for p in cliProc.params:
    if p.kind == nnkEmpty: continue
    p[0] = skipPragma p[0]

  debugMacroResult "CLI Code"

proc load*(f: TypedInputFile): f.ContentType =
  when f.Format is Unspecified or f.ContentType is Unspecified:
    {.fatal: "To use `InputFile.load`, please specify the Format and ContentType of the file".}

  when f.Format is Txt:
    # TODO: implement a proper Txt serialization format
    mixin init
    f.ContentType.init readFile(f.string).string
  else:
    mixin loadFile
    loadFile(f.Format, f.string, f.ContentType)

