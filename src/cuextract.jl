using DWARF
@osx_only using MachO
@linux_only using ELF
import ObjFileBase: DebugSections

tag_filter(which_tag, arr) = filter(x->DWARF.tag(x) == which_tag, arr)
tag_filter(which_tag::Vector, arr) = filter(x->(DWARF.tag(x) in which_tag), arr)

immutable Subprogram
    name::AbstractString
    linkage_name::AbstractString
    low_pc::UInt
    high_pc::UInt
    fbreg::UInt
    variables::Dict
end

immutable CompilationUnit
    SPs::Vector{Subprogram}
    low_pc::UInt
    high_pc::UInt
end

function process_cus(debugoh)
    dbgs = debugsections(debugoh);
    strtab = load_strtab(dbgs.debug_str)
    process_cus(dbgs, strtab)
end

function process_SP(SP, strtab)
    sp_low = (-1 % UInt); sp_high = 0; fbreg = (-1 % UInt)
    linkage_name = ""; name = ""
    for at in DWARF.attributes(SP)
        tag = DWARF.tag(at)
        if tag == DWARF.DW_AT_low_pc
            sp_low = convert(UInt,at)
        elseif tag == DWARF.DW_AT_high_pc
            sp_high = convert(UInt,at)
        elseif tag == DWARF.DW_AT_linkage_name ||
               tag == DWARF.DW_AT_MIPS_linkage_name
            linkage_name = bytestring(at,strtab)
        elseif tag == DWARF.DW_AT_frame_base
            # Simple for now
            fbreg = at.content[1]-DWARF.DW_OP_reg0
        elseif tag == DWARF.DW_AT_name
            name = bytestring(at,strtab)
        end
    end
    variables = Dict{Symbol,Any}()
    for v in SP.children
        name = nothing
        value = 0
        for at in DWARF.attributes(v)
            tag = DWARF.tag(at)
            if tag == DWARF.DW_AT_location
                value = at
            elseif tag == DWARF.DW_AT_const_value
                value = (-1 % UInt)
            elseif tag == DWARF.DW_AT_name
                name = bytestring(at, strtab)
            end
        end
        if name !== nothing
            variables[symbol(name)] = value
        end
    end
    Subprogram(name, linkage_name, sp_low, sp_high, fbreg, variables)    
end

function process_tree(tree, strtab)
    low = (-1 % UInt); high = 0
    for at in DWARF.attributes(tree)
        tag = DWARF.tag(at)
        if tag == DWARF.DW_AT_low_pc
            low = convert(UInt,at)
        elseif tag == DWARF.DW_AT_high_pc
            high = convert(UInt,at)
        end
    end
    subprograms = map(tag_filter(DWARF.DW_TAG_subprogram,tree.children)) do SP
        process_SP(SP, strtab)
    end
    CompilationUnit(subprograms, low, high)  
end
process_tree(tree::DWARF.DIETreeRef) = process_tree(tree.tree, tree.strtab)

process_cus(dbgs::DebugSections, strtab) = map(x->process_tree(x,strtab), DIETrees(dbgs))

function sections_for_oh(oh)
    dorelocate = false
    if isa(oh,MachO.MachOHandle)
        dorelocate = readheader(oh).filetype == MachO.MH_OBJECT
        sects = MachO.Sections(first(filter(LoadCmds(oh)) do lc
            isa(lc.cmd, MachO.segment_commands) && segname(lc) == "__TEXT"
        end))
        sects
    elseif isa(oh,ELF.ELFHandle)
        sects = ELF.Sections(oh)
    else
        error("Object file type unsupported")
    end
    (dorelocate, sects)
end
