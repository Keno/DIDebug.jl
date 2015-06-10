using DWARF

tag_filter(which_tag, arr) = filter(x->DWARF.tag(x) == which_tag, arr)

function investigate2(oh; dumpsource = false, dumpdies = false)
    sects = ELF.Sections(oh)

    # Relocate the object file
    new_buf = copy(oh.io)
    seekstart(new_buf)
    ELF.relocate!(new_buf,oh)
    seekstart(new_buf)
    oh = readmeta(new_buf)

    dbgs = debugsections(oh);
    tree = read(oh, DWARF.DIETree)
    strtab = ELF.load_strtab(dbgs.debug_str)

    dumpdies && show(STDOUT, tree; strtab = strtab)

    subprograms = collect(tag_filter(DWARF.DW_TAG_subprogram, tree.children))
    linkage_names = map(subprograms) do SP
        linkage = bytestring(first(tag_filter(DWARF.DW_AT_linkage_name, DWARF.attributes(SP))),strtab)
    end
    names = map(subprograms) do SP
        linkage = bytestring(first(tag_filter(DWARF.DW_AT_name, DWARF.attributes(SP))),strtab)
    end
    llvmf = map(FindFunctionNamed,linkage_names)
    juliaf = map(x->x == C_NULL ? nothing : getLam(x),llvmf)
    if dumpsource
        for i = 1:length(llvmf)
            print(Base.uncompressed_ast(juliaf[i]).args[3])
            dump(llvmf[i])
        end
    end
    for i = 1:length(juliaf)
        println("Debug Info for ",names[i])
        if juliaf[i] == nothing
            println("AST not found")
            continue
        end
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
    text = first(filter(x->sectionname(x)==".text",ELF.Sections(oh)))
    disassemble2(sectionaddress(text),sectionsize(text); rangelists=rangelists(oh))
    (llvmf, juliaf)
end
