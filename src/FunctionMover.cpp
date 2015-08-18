#ifndef FUNCTIONMOVER_CPP
#define FUNCTIONMOVER_CPP

#include "llvm/Transforms/Utils/ValueMapper.h"
#include "llvm/Transforms/Utils/Cloning.h"
#include "llvm/IR/DebugInfo.h"

using namespace llvm;
extern ExecutionEngine *jl_ExecutionEngine;
extern std::map<Value *, void*> llvm_to_jl_value;
extern TargetMachine *jl_TargetMachine;

llvm::LLVMContext &jl_LLVMContext = llvm::getGlobalContext();
extern "C" {
    extern void jl_error(const char *str);
}

class FunctionMover2 : public ValueMaterializer
{
public:
    FunctionMover2(llvm::Module *dest, DICompileUnit *TargetCU = nullptr, bool copyDependencies = true) :
        ValueMaterializer(), TargetCU(TargetCU), VMap(), destModule(dest), copyDependencies(true)
    {
    }
    SmallVector<Metadata *, 16> NewSPs;
    DICompileUnit *TargetCU;
    ValueToValueMapTy VMap;
    llvm::Module *destModule;
    bool copyDependencies;
    llvm::Function *clone_llvm_function2(llvm::Function *toClone)
    {
        Function *NewF = Function::Create(toClone->getFunctionType(),
                                          Function::PrivateLinkage,
                                          toClone->getName(),
                                          this->destModule);
        ClonedCodeInfo info;
        Function::arg_iterator DestI = NewF->arg_begin();
        for (Function::const_arg_iterator I = toClone->arg_begin(), E = toClone->arg_end(); I != E; ++I) {
            DestI->setName(I->getName());    // Copy the name over...
            this->VMap[I] = DestI++;        // Add mapping to VMap
        }

        // Necessary in case the function is self referential
        this->VMap[toClone] = NewF;

        // Clone and record the subprogram
        CloneDebugInfoMetadata(NewF, toClone, this->VMap);

        SmallVector<ReturnInst*, 8> Returns;
        llvm::CloneFunctionInto(NewF,toClone,this->VMap,true,Returns,"",NULL,NULL,this);

        return NewF;
    }

    void finalize()
    {
        if (TargetCU != nullptr)
        {
            // Record old subprograms
            for (auto *SP : TargetCU->getSubprograms())
                NewSPs.push_back(SP);
            TargetCU->replaceSubprograms(MDTuple::get(TargetCU->getContext(), NewSPs));
            NewSPs.clear();
        }
    }

    // Find the MDNode which corresponds to the subprogram data that described F.
    DISubprogram *FindSubprogram(const Function *F,
                                        DebugInfoFinder &Finder) {
      for (DISubprogram *Subprogram : Finder.subprograms()) {
        if (Subprogram->describes(F))
          return Subprogram;
      }
      return nullptr;
    }


    // Clone the module-level debug info associated with OldFunc. The cloned data
    // will point to NewFunc instead.
    void CloneDebugInfoMetadata(Function *NewFunc, const Function *OldFunc,
                                ValueToValueMapTy &VMap) {
      DebugInfoFinder Finder;
      Finder.processModule(*OldFunc->getParent());

      const DISubprogram *OldSubprogramMDNode = FindSubprogram(OldFunc, Finder);
      if (!OldSubprogramMDNode) return;

      // Ensure that OldFunc appears in the map.
      // (if it's already there it must point to NewFunc anyway)
      VMap[OldFunc] = NewFunc;
      auto *NewSubprogram =
          cast<DISubprogram>(MapMetadata(OldSubprogramMDNode, VMap));

      NewSPs.push_back(NewSubprogram);
    }

    virtual Value *materializeValueFor (Value *V)
    {
        Function *F = dyn_cast<Function>(V);
        if (F) {
            if (F->isIntrinsic()) {
                return destModule->getOrInsertFunction(F->getName(),F->getFunctionType());
            }
            if ((F->isDeclaration() || F->getParent() != destModule) && copyDependencies) {
                // Try to find the function in any of the modules known to MCJIT
                Function *shadow = jl_ExecutionEngine->FindFunctionNamed(F->getName().str().c_str());
                if (shadow != NULL && !shadow->isDeclaration()) {
                    Function *oldF = destModule->getFunction(F->getName());
                    if (oldF)
                        return oldF;
                    return clone_llvm_function2(shadow);
                }
                else if (!F->isDeclaration()) {
                    return clone_llvm_function2(F);
                }
            }
            // Still a declaration and still in a different module
            if (F->isDeclaration() && F->getParent() != destModule) {
                // Create forward declaration in current module
                return destModule->getOrInsertFunction(F->getName(),F->getFunctionType());
            }
        }
        else if (isa<GlobalVariable>(V)) {
            GlobalVariable *GV = cast<GlobalVariable>(V);
            assert(GV != NULL);
            GlobalVariable *oldGV = destModule->getGlobalVariable(GV->getName());
            if (oldGV != NULL)
                return oldGV;
            GlobalVariable *newGV = new GlobalVariable(*destModule,
                GV->getType()->getElementType(),
                GV->isConstant(),
                GlobalVariable::ExternalLinkage,
                NULL,
                GV->getName());
            newGV->copyAttributesFrom(GV);
            if (GV->isDeclaration())
                return newGV;
            std::map<Value*, void *>::iterator it;
            it = llvm_to_jl_value.find(GV);
            if (it != llvm_to_jl_value.end()) {
                newGV->setInitializer(Constant::getIntegerValue(GV->getType()->getElementType(),APInt(sizeof(void*)*8,(intptr_t)it->second)));
                newGV->setConstant(true);
            }
            else if (GV->hasInitializer()) {
                Value *C = MapValue(GV->getInitializer(),VMap,RF_None,NULL,this);
                newGV->setInitializer(cast<Constant>(C));
            }
            return newGV;
        }
        return NULL;
    };
};

llvm::Value *MapFunction(llvm::Function *f, FunctionMover2 *mover)
{
    llvm::Value *ret = llvm::MapValue(f,mover->VMap,llvm::RF_None,nullptr,mover);
    mover->finalize();
    return ret;
}
#endif //FUNCTIONMOVER_CPP
