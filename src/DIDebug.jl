module DIDebug

using Cxx; using JITTools; using ELF; using ObjFileBase; using DataStructures; using DWARF

import JITTools: buffer, datasize, datapointer
import ObjFileBase: readmeta, getSectionLoadAddress

export julia_passes

include(Pkg.dir("Cxx","test","llvmincludes.jl"))
if isdefined(Base, :active_repl)
   include(Pkg.dir("Cxx","src","CxxREPL","replpane.jl"))
end

addHeaderDir(joinpath(JULIA_HOME,"..","..","deps","llvm-svn","lib"))
cxx"""
#include "llvm/AsmParser/Parser.h"
#include "llvm/ExecutionEngine/JITEventListener.h"
#include "llvm/ExecutionEngine/ObjectMemoryBuffer.h"
#include "llvm/IR/LegacyPassManager.h"
#include "llvm/IR/LegacyPassManager.h"
#include "llvm/IR/DiagnosticPrinter.h"
#include "llvm/CodeGen/Passes.h"
#include "ExecutionEngine/MCJIT/MCJIT.h"
#include "llvm/Analysis/TargetTransformInfo.h"
#include "llvm/Analysis/Passes.h"
#include "llvm/Transforms/Scalar.h"
#include "llvm/Transforms/Vectorize.h"
#include "llvm/CodeGen/MachineFunctionAnalysis.h"
#include "llvm/CodeGen/MachineModuleInfo.h"
#include "llvm/Target/TargetLoweringObjectFile.h"
#include "llvm/CodeGen/MachineFunction.h"
#include "llvm/IR/DIBuilder.h"
#include "llvm/Support/TargetSelect.h"
#include "llvm/Support/TargetRegistry.h"
#include "llvm/MC/SubtargetFeature.h"
#include "llvm/MC/MCDisassembler.h"
#include "llvm/MC/MCRegisterInfo.h"
#include "llvm/MC/MCSubtargetInfo.h"
#include "llvm/MC/MCAsmInfo.h"
#include "llvm/MC/MCInstPrinter.h"
#include "llvm/MC/MCInstrInfo.h"
#include "llvm/MC/MCInst.h"
using namespace llvm;
"""

cxxparse(readall(Pkg.dir("DIDebug","src","FunctionMover.cpp")))

immutable LoadedObjectInfo
    LOI::pcpp"llvm::RuntimeDyld::LoadedObjectInfo"
end

immutable ObjectFile
    file::pcpp"llvm::object::ObjectFile"
end
Base.convert(::Type{pcpp"llvm::object::ObjectFile"}, x::ObjectFile) = x.file
Cxx.cppconvert(x::ObjectFile) = x.file

datasize(obj::ObjectFile) = icxx"$obj->getData().size();"
datapointer(obj::ObjectFile) = icxx"$obj->getData().data();"
readmeta(obj::ObjectFile) = readmeta(buffer(obj))

function parseIR(str)
    icxx"""
        llvm::SMDiagnostic Err;
        auto mod = llvm::parseAssembly(
            llvm::MemoryBufferRef(
            llvm::StringRef($(pointer(str)),$(sizeof(str))),
            llvm::StringRef("<in-memory>")),
            Err, jl_LLVMContext);
        if (mod == nullptr)
        {
            std::string message = "Failed to parse LLVM Assembly: \n";
            llvm::raw_string_ostream stream(message);
            Err.print("julia",stream,true);
            jl_error(stream.str().c_str());
        }
        return mod.release();
    """
end

function parseBitcode(str)
    icxx"""
        std::string Message;
        raw_string_ostream Stream(Message);
        DiagnosticPrinterRawOStream DP(Stream);
        ErrorOr<std::unique_ptr<Module>> ModuleOrErr = llvm::parseBitcodeFile(
            llvm::MemoryBufferRef(
            llvm::StringRef($(pointer(str)),$(sizeof(str))),
            llvm::StringRef("<in-memory>")),
            jl_LLVMContext, [&](const DiagnosticInfo &DI) { DI.print(DP); });

        if (ModuleOrErr.getError()) {
            Stream.flush();
            jl_error(Message.c_str());
        }

        return ModuleOrErr.get().release();
    """
end

function getSectionLoadAddress(L::LoadedObjectInfo, Name::ByteString)
    Addr = icxx"$(L.LOI)->getSectionLoadAddress($(pointer(Name)));"
    Addr == C_NULL && error("Section Not loaded or not found")
    Addr
end

getSectionLoadAddress(L::LoadedObjectInfo, sec) = getSectionLoadAddress(L,sectionname(sec))

function findObjForAddr(AddrMap, objects, addr)
    searchsortedlast(AddrMap, addr)
end

cxx"""
static llvm::object::OwningBinary<llvm::object::ObjectFile>
emitObject(llvm::TargetMachine *TM, llvm::Module *M) {
  llvm::legacy::PassManager PM;

  M->setDataLayout(TM->createDataLayout());

  // The RuntimeDyld will take ownership of this shortly
  llvm::SmallVector<char, 4096> ObjBufferSV;
  llvm::raw_svector_ostream ObjStream(ObjBufferSV);
  llvm::MCContext *Ctx;

  // Turn the machine code intermediate representation into bytes in memory
  // that may be executed.
  if (TM->addPassesToEmitMC(PM, Ctx, ObjStream, true))
    llvm::report_fatal_error("Target does not support MC emission!");

  // Initialize passes.
  PM.run(*M);

  std::unique_ptr<llvm::MemoryBuffer> CompiledObjBuffer(
                                new llvm::ObjectMemoryBuffer(std::move(ObjBufferSV)));

  llvm::ErrorOr<std::unique_ptr<llvm::object::ObjectFile>> LoadedObject =
    llvm::object::ObjectFile::createObjectFile(CompiledObjBuffer->getMemBufferRef());
  llvm::object::OwningBinary<llvm::object::ObjectFile> Obj(std::move(LoadedObject.get()),std::move(CompiledObjBuffer));

  return Obj;
}

static std::unique_ptr<llvm::RuntimeDyld::LoadedObjectInfo>
loadObject(llvm::ExecutionEngine *EE, llvm::object::OwningBinary<llvm::object::ObjectFile> Obj)
{
    return std::unique_ptr<llvm::RuntimeDyld::LoadedObjectInfo>{nullptr}; // ((llvm::MCJIT*)EE)->addObjectFile(std::move(Obj));
}

static std::unique_ptr<llvm::RuntimeDyld::LoadedObjectInfo>
loadModule(llvm::TargetMachine *TM, llvm::ExecutionEngine *EE, llvm::Module *M)
{
    return loadObject(EE,emitObject(TM,M));
}

void RunFPM(llvm::legacy::FunctionPassManager *FPM, llvm::Module *M)
{
    llvm::Module::FunctionListType &flist = M->getFunctionList();
    auto it = flist.begin();
    for(;it != flist.end(); ++it)
        FPM->run(*it);
}

/// addPassesToX helper drives creation and initialization of TargetPassConfig.
legacy::PassManager *createPassManager(LLVMTargetMachine *TM,
                                          MachineFunctionAnalysis *MFA,
                                          AnalysisID StopAfter) {
  legacy::PassManager *PM = new legacy::PassManager;

  // Add internal analysis passes from the target machine.
  PM->add(createTargetTransformInfoWrapperPass(TM->getTargetIRAnalysis()));

  // Targets may override createPassConfig to provide a target-specific
  // subclass.
  TargetPassConfig *PassConfig = TM->createPassConfig(*PM);
  PassConfig->setStartStopPasses(nullptr, nullptr, StopAfter);

  // Set PassConfig options provided by TargetMachine.
  PassConfig->setDisableVerify(false);

  PM->add(PassConfig);

  PassConfig->addIRPasses();

  PassConfig->addCodeGenPrepare();

  PassConfig->addPassesToHandleExceptions();

  PassConfig->addISelPrepare();

  // Install a MachineModuleInfo class, which is an immutable pass that holds
  // all the per-module stuff we're generating, including MCContext.
  MachineModuleInfo *MMI = new MachineModuleInfo(
      *TM->getMCAsmInfo(), *TM->getMCRegisterInfo(), TM->getObjFileLowering());
  PM->add(MMI);

  // Set up a MachineFunction for the rest of CodeGen to work on.
  PM->add(MFA);

  //TM->setFastISel(true);

  // Ask the target for an isel.
  if (PassConfig->addInstSelector())
    return nullptr;

  PassConfig->addMachinePasses();

  PassConfig->setInitialized();

  return PM;
}
"""

function setup_FPM(mod,passes)
    # Initialize the optimization passes
    FPM = @cxxnew llvm::legacy::FunctionPassManager(mod)
    icxx"$FPM->add(createTargetTransformInfoWrapperPass(jl_TargetMachine->getTargetIRAnalysis()));";
    for p in passes
        add(FPM, @eval @cxx $p())
    end
    @cxx FPM->doInitialization();
    FPM
end

# This is due to a bug in staged functions
# force add to specialize
add{T}(FPM,x::T) = @cxx FPM->add(x)

julia_passes = [
    :createTypeBasedAliasAnalysisPass,
    :createCFGSimplificationPass,
    :createPromoteMemoryToRegisterPass,
    :createInstructionCombiningPass,
    :createScalarReplAggregatesPass,
    :createInstructionCombiningPass,
    :createJumpThreadingPass,
    :createInstructionCombiningPass,
    :createReassociatePass,
    :createEarlyCSEPass,
    :createLoopIdiomPass,
    :createLoopRotatePass,
#    :createLowerSimdLoopPass,
    :createLICMPass,
    :createLoopUnswitchPass,
    :createInstructionCombiningPass,
    :createIndVarSimplifyPass,
    :createLoopDeletionPass,
    :createSimpleLoopUnrollPass,
    :createLoopVectorizePass,
    :createInstructionCombiningPass,
    :createGVNPass,
    :createSCCPPass,
    :createSinkingPass,
    :createInstructionSimplifierPass,
    :createInstructionCombiningPass,
    :createJumpThreadingPass,
    :createDeadStoreEliminationPass,
    :createAggressiveDCEPass,
];

counter = 0
function setup_test(f, passes = julia_passes, dependencies = true)
    mod = @cxxnew llvm::Module(pointer("test"),icxx"jl_LLVMContext;")
    CU = icxx"""
        Module *m = $mod;
        m->addModuleFlag(llvm::Module::Warning, "Dwarf Version",4);
        m->addModuleFlag(llvm::Module::Error, "Debug Info Version",
          llvm::DEBUG_METADATA_VERSION);
        DIBuilder DIB(*m);
        DICompileUnit *CU = DIB.createCompileUnit(0x01, "test.jl", ".", "julia", true, "", 0);
        DIB.finalize();
        CU;
    """
    FPM = setup_FPM(mod,passes)
    mover = @cxxnew FunctionMover2(mod, CU, dependencies)
    r = @cxx MapFunction(f,mover)
    global counter += 1
    name = string("foobar",counter)
    @cxx r->setName(pointer(name))
    @cxx pcpp"llvm::Function"(r.ptr)->setLinkage(@cxx llvm::GlobalValue::ExternalLinkage)
    #@cxx r->dump()
    @cxx RunFPM(FPM,mod)
    #icxx"jl_ExecutionEngine->addModule(std::unique_ptr<Module>{$mod});"
    name, mod
end

MF_passes = [
    (@cxx &llvm::ExpandISelPseudosID)
    (@cxx &llvm::PrologEpilogCodeInserterID)
    (@cxx &llvm::LocalStackSlotAllocationID)
]

function run_pm(f, passes = julia_passes, dependencies = true, StopAfter = (@cxx &llvm::VirtRegRewriterID))
    name, mod = setup_test(f,passes,dependencies)
    tm = @cxx (@cxx jl_ExecutionEngine)->getTargetMachine()
    ltm = pcpp"llvm::LLVMTargetMachine"(tm.ptr)
    mfa = @cxxnew MachineFunctionAnalysis(*(ltm))
    PM = @cxx createPassManager(ltm,mfa,StopAfter)
    @cxx PM->run(*(mod))
    mod, mfa
end

function FindFunctionNamed(str)
    icxx"jl_ExecutionEngine->FindFunctionNamed($(pointer(str)));"
end

function WriteBitcodeToFile(fname,mod)
    icxx"""
        std::error_code err;
        StringRef fname_ref = StringRef($(pointer(fname)));
        raw_fd_ostream OS(fname_ref, err, sys::fs::F_None);
        WriteBitcodeToFile($mod, OS);
    """
end

function getLam(llvmf)
  lam = icxx"""cast<ConstantInt>(cast<ConstantAsMetadata>(
    $llvmf->getMetadata("lam")->getOperand(0).get())->getValue())->getZExtValue();"""
  unsafe_pointer_to_objref(convert(Ptr{Void},lam))
end

include("disassembler.jl")
include("investigate.jl")

end # module
