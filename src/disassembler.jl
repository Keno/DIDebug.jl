immutable DisAsmContext
  MAI::pcpp"llvm::MCAsmInfo"
  MRI::pcpp"llvm::MCRegisterInfo"
  MII::pcpp"llvm::MCInstrInfo"
  MOFI::pcpp"llvm::MCObjectFileInfo"
  MCtx::pcpp"llvm::MCContext"
  MSTI::pcpp"llvm::MCSubtargetInfo"
  DisAsm::pcpp"llvm::MCDisassembler"
  MIP::pcpp"llvm::MCInstPrinter"
end

function DisAsmContext()
  TripleName = icxx"""
    llvm::InitializeNativeTargetAsmParser();
    llvm::InitializeNativeTargetDisassembler();

    // Get the host information
    std::string TripleName;
    if (TripleName.empty())
        TripleName = sys::getDefaultTargetTriple();
    TripleName;
  """

  TheTarget = icxx"""
    std::string err;
    TargetRegistry::lookupTarget($TripleName, err);
  """

  MAI  = icxx" $TheTarget->createMCAsmInfo(*$TheTarget->createMCRegInfo($TripleName),$TripleName); "
  MII  = icxx" $TheTarget->createMCInstrInfo(); "
  MRI  = icxx" $TheTarget->createMCRegInfo($TripleName); "
  MOFI = icxx" new MCObjectFileInfo; "
  MCtx = icxx" new MCContext($MAI, $MRI, $MOFI); "
  icxx" $MOFI->InitMCObjectFileInfo($TripleName, Reloc::Default, CodeModel::Default, *$MCtx); "
  MSTI = icxx"""
    Triple TheTriple(Triple::normalize($TripleName));
    SubtargetFeatures Features;
    Features.getDefaultSubtargetFeatures(TheTriple);
    std::string MCPU = sys::getHostCPUName();
    $TheTarget->createMCSubtargetInfo($TripleName, MCPU, Features.getString());
  """

  DisAsm = icxx" $TheTarget->createMCDisassembler(*$MSTI, *$MCtx); "

  MIP = icxx"""
      int AsmPrinterVariant = $MAI->getAssemblerDialect();
      $TheTarget->createMCInstPrinter(
          Triple($TripleName), AsmPrinterVariant, *$MAI, *$MII, *$MRI);
  """

  DisAsmContext(MAI, MRI, MII, MOFI, MCtx, MSTI, DisAsm, MIP)
end

function getInstruction(data::Vector{UInt8}, offset; ctx = DisAsmContext())
  Inst = icxx" new MCInst; "
  InstSize = icxx"""
    uint8_t *Base = (uint8_t*)$(convert(Ptr{Void},pointer(data)));
    uint64_t Total = $(sizeof(data));
    uint64_t Offset = $offset;
    uint64_t LoadAddress = 0;
    uint64_t InstSize;
    MCDisassembler::DecodeStatus S;
    S = $(ctx.DisAsm)->getInstruction(*$Inst, InstSize,
        ArrayRef<uint8_t>(Base+Offset, Total-Offset),
          LoadAddress + Offset, /*REMOVE*/ nulls(), nulls());
    switch (S) {
      case MCDisassembler::SoftFail:
      case MCDisassembler::Fail:
        delete $Inst;
        return (uint64_t)0;
      case MCDisassembler::Success:
        return InstSize;
    }
  """
  if InstSize == C_NULL
    error("Invalid Instruction")
  end
  (Inst, InstSize)
end

#=
function disassembleInstruction(f::Function, data::Vector{UInt8}, offset; ctx = DisAsmContext())
  icxx"""
    uint8_t *Base = (uint8_t*)$(convert(Ptr{Void},pointer(data)));
    uint64_t Total = $(sizeof(data));
    uint64_t Offset = $offset;
    uint64_t LoadAddress = 0;
    uint64_t InstSize;
    MCInst Inst;
    MCDisassembler::DecodeStatus S;
    S = $(ctx.DisAsm)->getInstruction(Inst, InstSize,
        ArrayRef<uint8_t>(Base+Offset, Total-Offset),
          LoadAddress + Offset, /*REMOVE*/ nulls(), nulls());
    switch (S) {
      case MCDisassembler::SoftFail:
      case MCDisassembler::Fail:
        return 0;
      case MCDisassembler::Success:
        :(f(icxx"&Inst;"); nothing);
        return InstSize;
    }
  """
end
=#

function Base.show(io::IO, Inst::pcpp"llvm::MCInst"; ctx = DisAsmContext())
  print(io,bytestring(icxx"""
  std::string O;
  raw_string_ostream OS(O);
  ($(ctx.MIP))->printInst(($Inst), OS, "", *$(ctx.MSTI));
  OS.flush();
  O;
  """))
end

Base.show(Inst::pcpp"llvm::MCInst"; ctx = DisAsmContext()) = show(Base.STDOUT, Inst)
Base.repr(Inst::pcpp"llvm::MCInst"; ctx = DisAsmContext()) =
  (buf = IOBuffer(); show(buf, Inst); takebuf_string(buf))


free(x::pcpp"llvm::MCInst") = icxx" delete $x; "

function loclist2rangelist{T}(list::DWARF.LocationList{T})
  rangelist = Array(UnitRange{T},0)
  for entry in list.entries
    push!(rangelist, entry.first:entry.last)
  end
  rangelist
end

function rangelists(dbgs)
  seek(dbgs.oh, sectionoffset(dbgs.debug_loc))
  lists = Array(Vector{UnitRange{UInt64}},0)
  while position(dbgs.oh) < sectionoffset(dbgs.debug_loc)+sectionsize(dbgs.debug_loc)
      push!(lists,loclist2rangelist(read(dbgs.oh, DWARF.LocationList{UInt64})))
  end
  lists
end

function rangelist(dbgs, offset)
    seek(dbgs.oh, sectionoffset(dbgs.debug_loc)+offset)
    loclist2rangelist(read(dbgs.oh, DWARF.LocationList{UInt64}))
end

default_colors = [:blue, :red, :green, :yellow, :purple]
function disassemble2(data::Vector{UInt8}, instrange = nothing; io = STDOUT,
    ctx = DisAsmContext(), rloffset = 0, rangelists = [], colors = default_colors, offset = 0)
  Offset = instrange !== nothing ? first(instrange) - offset : 0
  while Offset < sizeof(data) && (instrange === nothing || Offset <= last(instrange)-offset)
    (Inst, InstSize) = getInstruction(data, Offset)
    print(io,"0x",hex(Offset+offset,2*sizeof(Offset)))
    print(io,":")
    str = repr(Inst; ctx = ctx)
    # This is bad, but I need things to line up
    lastt = findlast(str, '\t')
    rest = str[(lastt+1):end]
    print(io, str[1:lastt])
    if lastt == 1
      print(io,rest,'\t')
      rest = ""
    end
    printfield(io, rest, 25; align = :left)
    # Print applicable range lists
    for (i,rangelist) in enumerate(rangelists)
      print(io," ")
      found = false
      color = colors[mod1(i,length(colors))]
      for range in rangelist
        # If this is the start of a range
        if Offset+offset == first(range)+rloffset
          print_with_color(color,io,"x")
        # Or the last
        elseif last(range)+rloffset == Offset+offset+InstSize
          print_with_color(color,io,"x")
        elseif first(range)+rloffset <= Offset + offset < last(range)+rloffset
          print_with_color(color,io,"|")
        else
          continue
        end
        found = true
        break
      end
      found || print(io," ")
    end
    println(io)
    free(Inst)
    Offset += InstSize
  end
end
function disassemble2(base, size; kwargs...)
    data = pointer_to_array(convert(Ptr{UInt8},base), (size,), false)
    disassemble2(data; kwargs...)
end


function disassemble(base, size, ctx = DisAsmContext())
  icxx"""
    uint64_t InstSize;
    uint8_t *Base = (uint8_t*)$(convert(Ptr{Void},base));
    uint64_t Total = $size;
    uint64_t LoadAddress = 0;
    for (uint64_t Offset = 0; Offset < Total; Offset += InstSize)
    {
      MCInst Inst;
      MCDisassembler::DecodeStatus S;

      S = $(ctx.DisAsm)->getInstruction(Inst, InstSize,
          ArrayRef<uint8_t>(Base+Offset, Total-Offset),
            LoadAddress + Offset, /*REMOVE*/ nulls(), nulls());

      switch (S) {
      case MCDisassembler::SoftFail:
      case MCDisassembler::Fail:
        return false;
      case MCDisassembler::Success:
          $(ctx.MIP)->printInst(&Inst, outs(), "", *$(ctx.MSTI));
          outs() << "\n";
        break;
      }
    }
    return true;
  """
end
