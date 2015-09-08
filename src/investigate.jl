using DWARF
using MachO
import ObjFileBase: DebugSections

tag_filter(which_tag, arr) = filter(x->DWARF.tag(x) == which_tag, arr)
tag_filter(which_tag::Vector, arr) = filter(x->(DWARF.tag(x) in which_tag), arr)

immutable Subprogram
    name::String
    linkage_name::String
    low_pc::UInt
    high_pc::UInt
    variables::Vector{UInt}
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

function process_cus(dbgs::DebugSections, strtab)
    didata = map(DIETrees(dbgs)) do tree
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
            sp_low = (-1 % UInt); sp_high = 0
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
                elseif tag == DWARF.DW_AT_name
                    name = bytestring(at,strtab)
                end
            end
            variables = map(SP.children) do v
                for at in DWARF.attributes(v)
                    tag = DWARF.tag(at)
                    if tag == DWARF.DW_AT_location
                        return isa(at,DWARF.Attributes.BlockAttribute) ?
                            (-1 % UInt) : convert(UInt,at)
                    elseif tag == DWARF.DW_AT_const_value
                        return (-1 % UInt)
                    end
                end
                return 0
            end
            Subprogram(name, linkage_name, sp_low, sp_high, variables)
        end
        CompilationUnit(subprograms, low, high)
    end
end

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

function investigate_function(io::IO, oh, dbgs, didata, name)
    sects = sections_for_oh(oh)[2]
    text = first(filter(x->contains(lowercase(bytestring(sectionname(x))),"text"),sects))
    for c in didata
        for sp in c.SPs
            if name != sp.linkage_name
                continue
            end
            rangelists = map(sp.variables) do loc
                if loc == 0
                    return []
                elseif loc == (-1 % UInt)
                    return UnitRange{UInt}[0:typemax(UInt)]
                else
                    return rangelist(dbgs,loc)
                end
            end
            println(io, "Dump for ", sp.name)
            range = sp.low_pc:sp.high_pc
            seek(oh,sectionoffset(text))
            data = readbytes(oh,sectionsize(text))
            disassemble2(data, range; io=io, rangelists = rangelists, rloffset = c.low_pc, offset = sectionoffset(text))
        end
    end
end

function investigate2(oh, debugoh=oh;
        dumpsource = false, dumpdies = false, dumploctables = false, fromproc = false)
    dorelocate = true


    # Relocate the object file
    if dorelocate
        new_buf = copy(oh.io)
        seekstart(new_buf)
        ELF.relocate!(new_buf,oh)
        seekstart(new_buf)
        oh = readmeta(new_buf)
    end

    dbgs = debugsections(debugoh);
    strtab = load_strtab(dbgs.debug_str)

    if dumpdies
        dt = DIETrees(dbgs)
        it = start(dt)
        while !done(dt, it)
            tree, it = next(dt, it)
            show(STDOUT, tree; strtab = strtab)
        end
    end

    didata = process_cus(dbgs, strtab)

#=
    llvmf = map(FindFunctionNamed,linkage_names)
    juliaf = map(x->x == C_NULL ? nothing : getLam(x),llvmf)
    if dumpsource
        for i = 1:length(llvmf)
            print(Base.uncompressed_ast(juliaf[i]).args[3])
            icxx" $(llvmf[i])->getParent()->dump(); "
        end
    end
    text = first(filter(x->contains(lowercase(bytestring(sectionname(x))),"text"),sects))
    rls = rangelists(dbgs)
    for i = 1:length(juliaf)
        println("Debug Info for ",names[i])
        if juliaf[i] == nothing
            println("AST not found")
        else
            ast = Base.uncompressed_ast(juliaf[i])
            println("Parameters:")
            params = ast.args[1]
            for var in params
                println(" - ",var.args[1])
            end
            lvars = ast.args[2][1]
            if !isempty(lvars)
                println("Local Variables:")
                for var in lvars
                    println(" - ",var[1])
                end
            end
        end
        range = ranges[i]
        @show range
        this_rls = collect(filter(x->!isempty(x),map(rls) do rl
            collect(filter(rl) do entry
                first(range) <= first(entry) && last(entry) <= last(range)
            end)
        end))
        if fromproc
            disassemble2(sectionaddress(text),sectionsize(text), range; rangelists=this_rls)
        else
            seek(oh,sectionoffset(text))
            data = readbytes(oh,sectionsize(text))
            disassemble2(data, range; rangelists=this_rls, offset = sectionoffset(text))
        end
    end
    if dumploctables
        seek(oh, sectionoffset(dbgs.debug_loc))
        while position(oh) < sectionoffset(dbgs.debug_loc)+sectionsize(dbgs.debug_loc)
            show(read(oh, DWARF.LocationList{UInt64}))
        end
    end
    (llvmf, juliaf)
=#
end
