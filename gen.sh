#!/usr/bin/bash

#### VARIABLES ####

## SET THESE ##
os_ver=$(uname -v | cut -c 5-18)
mingw_ver=""
mingw_bin_32=""
mingw_bin_64=""

parser_dir=""
parser_profile_32=""
parser_profile_64=""
parser_profile_32_ntddk=""
parser_profile_64_ntddk=""

manual_adds="
-DCONST=\"const\"
-D__restrict__=\"\"
-D__always_inline__=\"inline\"
-D__gnu_inline__=\"inline\"
-D__builtin_va_list=\"void *\""

winapi_32_header="$PWD/winapi_32.h"
winapi_64_header="$PWD/winapi_64.h"
ntddk_32_header="$PWD/ntddk_32.h"
ntddk_64_header="$PWD/ntddk_64.h"

#### FUNCS ####
function create_header_file()
{
    for var in "${@:2}"
    do
        echo "$var"
    done
} >> "$1"

function create_c_file()
{
    # https://docs.microsoft.com/en-us/windows/win32/winprog/using-the-windows-headers
    echo "#define NTDDI_VERSION 0x0A000007" # make sure to check sdkddkver.h
    echo "#include <minwindef.h>"
    echo "#include <winnt.h>"
    echo "#include <ntddk.h>"
    echo "#include <wdm.h>" 
    echo "#include <ntifs.h>" 
    echo "#include <ndis.h>" 
    echo "#include <wmilib.h>"
} >> "$1"

function gen_parse_32()
{
    default_includes=$(echo "" | "$2" -xc -E -v - 2>&1 | sed -ne '/^#include <\.\.\.> search starts here:/,/End of search list./ p' | sed '1d;$d' | sed 's/^ /-I/g')
    compiler_paths=$(echo "" | "$2" -xc -E -v - 2>&1 | grep "COMPILER_PATH=" | tr '=:' '\n' | tail -n+2 | sed 's/^/-I/g')
    default_defines=$(echo "" | "$2" -std=c89 -dM -E - | sed 's/#define \([^[:space:]]\+\)[[:space:]]\+\(.*\)$/-D\1="\2"/g')

    echo "$3" >> "$1"
    create_header_file "$1" "$default_includes" "$compiler_paths" "$manual_adds" "$default_defines"
}

function gen_parse_32_ntddk()
{
    echo "$3"
    echo "-I/usr/i686-w64-mingw32/include/ddk"
    awk 'NR > 1' "$2"
} >> "$1"

function gen_parse_64()
{
    default_includes=$(echo "" | "$2" -std=c89 -xc -E -v - 2>&1 | sed -ne '/^#include <\.\.\.> search starts here:/,/End of search list./ p' | sed '1d;$d' | sed 's/^ /-I/g')
    compiler_paths=$(echo "" | "$2" -std=c89 -xc -E -v - 2>&1 | grep "COMPILER_PATH=" | tr '=:' '\n' | tail -n+2 | sed 's/^/-I/g')
    default_defines=$(echo "" | "$2" -std=c89 -dM -E - | sed 's/#define \([^[:space:]]\+\)[[:space:]]\+\(.*\)$/-D\1="\2"/g')

    echo "$3" >> "$1"
    create_header_file "$1" "$default_includes" "$compiler_paths" "$manual_adds" "$default_defines"
}

function gen_parse_64_ntddk()
{
    echo "$3"
    echo "-I/usr/x86_64-w64-mingw32/include/ddk"
    awk 'NR > 1' "$2"
} >> "$1"

function gen_winapi()
{
    cat malware_headers.txt common_headers.txt | while read -r include; do echo "#include <${include}>"; done | "$2" -std=c89 -P -E - | 
    sed 's/__asm__ .*);/\/\*__asm__\*\//g' > "$1"
}

function gen_ntddk_32()
{
    create_c_file "$3"
    "$2" -I/usr/i686-w64-mingw32/include/ddk -std=c89 -P -E "$3" > "$1" 2>"/dev/null"
}

function gen_ntddk_64()
{
    create_c_file "$3"
    "$2" -I/usr/x86_64-w64-mingw32/include/ddk -std=c89 -P -E "$3" > "$1" 2>"/dev/null"
}

function inline_replace()
{
	if [[ "$#" -eq 2 ]];
	then
		count=0
		while IFS= read -r line;
		do
			if ! (( count % 2 ));
			then
				sed -i "$line""s/^/\/\*/" "$1"
			else
				sed -i "$line""s/$/\*\//" "$1"
			fi
			(( count+=1 ))
		done <<< "$2"
	elif [[ "$#" -eq 3 ]];
	then
		sed -i "$2""s/^/\/\*/" "$1"
		sed -i "$3""s/$/\*\//" "$1"
	fi
}

function remove_m_mm()
{    
    mms_one=$(awk -v begin_pat="^extern __inline" '$0 ~ begin_pat {	
        func_pat="^_+([mM]+|(l|t)zcnt[u]?|bextr|bls|cvtsh)[0-9]*"
        func_end="^}"
        first_line=NR;
        if (getline <= 0)
        {
            print("Failed to getline") > "/dev/stderr";
            exit;
        }
        else
        {
            multi_liner = match($0, "^__attribute|[[:space:]][[:space:]]__attribute");
            if (multi_liner != 0 && getline <= 0)
            {
                print("[multi-liner] failed to getline") > "/dev/stderr";
                exit;
            }
            if ($0 ~ func_pat)
            {
                while ($0 !~ func_end && getline > 0)
                {
                    continue;
                }
                if ($0 ~ func_end)
                {
                    print first_line;
                    print NR;
                }
            }
        }
    }' "$1")
}

function remove_misc()
{
    mms_two=$(awk -v pattern="^_encl[svu]+_u32|^_pconfig_u32" '$0 ~ pattern {
        func_end="return"
        first_line=NR-2;
        while ($0 !~ func_end && getline > 0)
        {
            continue;
        }
        if ($0 ~ func_end)
        {
            print first_line;
            print NR+1;
        }
    }' "$1")
}

function clean_ntddk_64()
{
    echo "[i] Cleaning out $1"

    remove_m_mm "$1" 
    remove_misc "$1"
 
    inline_replace "$1" "$mms_one"
    inline_replace "$1" "$mms_two"

    asm_lines=$(awk -v pattern="__asm__.*\\\(.*\\\(\\\*[a-zA-Z]+\\\)" '$0 ~ pattern {
        line=$0;
        sub(/\(\*/, "(/**/", $0); 
        print line;
        print $0;
    }' "$1")
    count=0
    lhs=""
    rhs=""
    while IFS= read -r line; 
    do 
        if ! (( count % 2));
        then
            lhs=$( printf '%s\n' "$line" | sed 's:[][\\/.^$*]:\\&:g');
        else
            rhs=$( printf '%s\n' "$line" | sed 's:[\\/&]:\\&:g;$!s/$/\\/');
            sed -i "s/$lhs/$rhs/g" "$1"
        fi
        (( count+=1 ));
    done <<< "$asm_lines"	

    asm_lines_two=$(awk -v pattern="__asm__.*\\\(.*\\\(+\\\*\\\(.*\\\)" '$0 ~ pattern { print NR; }' "$1")
    while IFS= read -r line;
    do
        sed -i "$line""s/^/\/\*/" "$1"
        sed -i "$line""s/$/\*\//" "$1"
    done <<< "$asm_lines_two"
    
    # HandleToULong to PtrToPtr32 static inlined funcs
    start_NR=$(awk -v pattern="HandleToULong" '$0 ~ pattern { print NR; }' "$1")
    end_NR=$(awk -v pattern="PtrToPtr32" '$0 ~ pattern { print NR; }' "$1")
    inline_replace "$1" "$start_NR" "$end_NR"

    # __faststorefence func
    start_NR=$(awk -v pattern="__faststorefence.*{" '$0 ~ pattern { print NR; }' "$1")
    (( end_NR=start_NR+2 ));
    inline_replace "$1" "$start_NR" "$end_NR"

    # TagBase
    tagbase=$(awk -v pattern=".*ULONG.*TagBase" '$0 ~ pattern {
        first_line=NR-2;
        end_pattern="^}"
        while ($0 !~ end_pattern && getline > 0)
        {
            continue;
        }
        if ($0 ~ end_pattern)
        {
            print first_line;
            print NR;
        }
    }' "$1")
    inline_replace "$1" "$tagbase"
    
    # _umul128 & _mul128
    muls=$(awk -v pattern=".*_[u]?mul128.*\\\)$" '$0 ~ pattern {
        end_pattern="^}"
        first_line=NR;
        while ($0 !~ end_pattern && getline > 0)
        {
            continue;
        }
        if ($0 ~ end_pattern)
        {
            print first_line;
            print NR;
        }
    }' "$1")
    inline_replace "$1" "$muls"

    # int2c
    lines=$(awk -v pattern=".*__int2c.*{$" '$0 ~ pattern { print NR+1; }' "$1")
    sed -i "$lines""s/__asm__ .*);/\/\*__asm__\*\//" "$1"

    # MarkAllocaS
    markalloc_lines=$(awk -v pattern="^.*MarkAllocaS" '$0 ~ pattern {
        end_pattern="return"
        first_line=NR;
        while ($0 !~ end_pattern && getline > 0)
        {
            continue;
        }
        if ($0 ~ end_pattern)
        {
            print first_line;
            print NR+1;
        }
    }' "$1")
    inline_replace "$1" "$markalloc_lines"

    # RtlSecureZeroMemory/RtlCheckBit
    rtl_lines=$(awk -v pattern="^Rtl(SecureZeroMemory|CheckBit)" '$0 ~ pattern {
        end_pattern="^}"
        first_line=NR-2;
        while ($0 !~ end_pattern && getline > 0)
        {
            continue;
        }
        if ($0 ~ end_pattern)
        {
            print first_line;
            print NR;
        }
        else
        {
            print("Rtl Functions not found") > "/dev/stderr";
            exit;
        }
    }' "$1")
    inline_replace "$1" "$rtl_lines"

    #NdisMWanIndicateRecieveComplete missing a , (??????????????????????????????????????)
    line=$(awk -v pattern="^NdisMWanIndicateReceiveComplete" '$0 ~ pattern { print NR+1; }' "$1")
    sed -i "$line""s/$/,/" "$1"
}
function clean_ntddk_32()
{
    echo "[i] Cleaning out $1."

    remove_m_mm "$1" 
    remove_misc "$1"
 
    inline_replace "$1" "$mms_one"
    inline_replace "$1" "$mms_two"

    asm_lines=$(awk -v pattern="__asm__.*\\\(.*\\\(\\\*[a-zA-Z]+\\\)" '$0 ~ pattern {
        line=$0;
        sub(/\(\*/, "(/**/", $0); 
        print line;
        print $0;
    }' "$1")
    count=0
    lhs=""
    rhs=""
    while IFS= read -r line; 
    do 
        if ! (( count % 2));
        then
            lhs=$( printf '%s\n' "$line" | sed 's:[][\\/.^$*]:\\&:g');
        else
            rhs=$( printf '%s\n' "$line" | sed 's:[\\/&]:\\&:g;$!s/$/\\/');
            sed -i "s/$lhs/$rhs/g" "$1"
        fi
        (( count+=1 ));
    done <<< "$asm_lines"	

    asm_lines_two=$(awk -v pattern="__asm__.*\\\(.*\\\(+\\\*\\\(.*\\\)" '$0 ~ pattern { print NR; }' "$1")
    while IFS= read -r line;
    do
        sed -i "$line""s/^/\/\*/" "$1"
        sed -i "$line""s/$/\*\//" "$1"
    done <<< "$asm_lines_two"
    
    interlock=$(awk -v pattern="^InterlockedBitTestAnd(Res|S)et" '$0 ~ pattern {
        first_line=NR-1; 
        end_pattern="^}"
        while ($0 !~ end_pattern && getline > 0)
        {
            continue;
        }
        if ($0 ~ end_pattern)
        {
            print first_line;
            print NR;
        }
    }' "$1")
    inline_replace "$1" "$interlock"

    # TagBase
    tagbase=$(awk -v pattern=".*ULONG.*TagBase" '$0 ~ pattern {
        first_line=NR-2;
        end_pattern="^}"
        while ($0 !~ end_pattern && getline > 0)
        {
            continue;
        }
        if ($0 ~ end_pattern)
        {
            print first_line;
            print NR;
        }
    }' "$1")
    inline_replace "$1" "$tagbase"

    # anonymous func
    line=$(awk -v pattern="PSLIST_HEADER ListHead)->Depth" '$0 ~ pattern { print NR; }' "$1")
    sed -i "$line""s/^/\/\*/" "$1"
    sed -i "$line""s/$/\*\//" "$1"

    #NdisMWanIndicateRecieveComplete missing a ,
    line=$(awk -v pattern="^NdisMWanIndicateReceiveComplete" '$0 ~ pattern { print NR+1; }' "$1")
    sed -i "$line""s/$/,/" "$1"
}

function clean_winapi_64()
{
    echo "[i] Cleaning out $1"
    remove_m_mm "$1"
    remove_misc "$1"
 
    inline_replace "$1" "$mms_one"
    inline_replace "$1" "$mms_two"
}


function clean_up()
{
    rm "$1"
    mv "$parser_profile_32" "$parser_dir"
    mv "$parser_profile_64" "$parser_dir"
    mv "$parser_profile_32_ntddk" "$parser_dir"
    mv "$parser_profile_64_ntddk" "$parser_dir"
}

echo "[i] Generating x86 parsing profile..."
gen_parse_32 "$parser_profile_32" "$mingw_bin_32" "$winapi_32_header"

echo "[i] Generating x86_64 parsing profile..."
gen_parse_64 "$parser_profile_64" "$mingw_bin_64" "$winapi_64_header"

echo "[i] Generating x86-ntddk parsing profile..."
gen_parse_32_ntddk "$parser_profile_32_ntddk" "$parser_profile_32" "$ntddk_32_header"

echo "[i] Generating x86_64-ntddk parsing profile..."
gen_parse_64_ntddk "$parser_profile_64_ntddk" "$parser_profile_64" "$ntddk_64_header"

echo "[i] Generating winapi_32 combined headers..."
gen_winapi "$winapi_32_header" "$mingw_bin_32" 

echo "[i] Generating winapi_64 combined header..."
gen_winapi "$winapi_64_header" "$mingw_bin_64"

echo "[i] Generating ntddk_32 combined header..."
gen_ntddk_32 "$ntddk_32_header" "$mingw_bin_32" "ntddk.c"

echo "[i] Generating ntddk_64 combined header..."
gen_ntddk_64 "$ntddk_64_header" "$mingw_bin_64" "ntddk.c"

echo "[i] Cleaning header files for parsing... This could take a few minutes."
clean_winapi_64 "$winapi_64_header"
clean_ntddk_32 "$ntddk_32_header"
clean_ntddk_64 "$ntddk_64_header"


echo "[i] Cleaning up..."
clean_up "ntddk.c"





