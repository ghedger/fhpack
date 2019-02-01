********************************
*                              *
* LZ4FH compression for 6502   *
* By Greg Hedger               *
* Version 0.5.0, February 2019 *
*                              *
* Refactored for size & speed  *
* by Peter Ferrie.             *
*                              *
* Developed with AS65.pl       *
* by Leeland Heins             *
********************************
           lst   off
           org   $6400

*
* Constants
*
lz4fh_magic       equ $66       ;ascii 'f'
tok_empty         equ 253
tok_eod           equ 254

MIN_MATCH_LEN      equ 4
MAX_MATCH_LEN      equ 255
MAX_LITERAL_LEN    equ 255
INITIAL_LEN        equ 15
INITIAL_LEN_SH4    equ $f0
EOD_MATCH_TOKEN    equ 254
EMPTY_MATCH_TOKEN  equ 253

overrun_check equ 0

*
* Variable storage
*
outPtr       equ   $ef        ;2b a1h
matchptr     equ   $f1        ;2b
literalsrcptr equ  $f3        ;2b
inPtr        equ   $f5        ;2b
flm_src      equ   $f7        ;2b
T0           equ   $f9        ;1b
T1           equ   $fa        ;1b
longestoffset equ  $fc        ;2b
ii           equ   $fe        ;2b

*
* ROM routines
*
bell     equ   $ff3a
monitor  equ   $ff69

*
* Parameters, stashed at the top of the text input
* buffer.  We use this, rather than just having them
* poked directly into the code, so that the 6502 and
* 65816 implementations work the same way without
* either getting weird.
*

adjustedmatch equ   $2ec       ;1b
mixedlengths  equ   $2ed       ;1b
longest       equ   $2ee       ;2b
maxmatchlen   equ   $2ef       ;2b
matchlen      equ   $2f0       ;1b
maxstartoffset equ  $2f2       ;2b
numliterals   equ   $2f4       ;1b
longestmatch  equ   $2f5       ;1b
matchoffset   equ   $2f6       ;2b
inEnd         equ   $2f8       ;2b
outEnd         equ   $2f8       ;2b
inLen         equ   $2fa       ;2b
inBuf         equ   $2fc       ;2b
in_dst        equ   $2fe       ;2b

entry
           jsr   comp_savezp    ;save off portion of zp we will use

           ;  size_t compressBufferGreedily(uint8_t* outBuf, const uint8_t* inBuf,
           ; size_t inLen)

           lda   in_dst         ;copy destination address to zero page
           sta   outPtr
           lda   in_dst+1
           sta   outPtr+1

                                ;init literals
           lda   #0
           sta   literalsrcptr
           sta   literalsrcptr+1
           sta   numliterals

                                ;calculate and set endpoint
           lda inBuf
           clc
           adc inLen
           sta inEnd
           lda inBuf+1
           adc inLen+1
           sta inEnd+1

                                ;set input ptr
           lda inBuf
           sta inPtr
           lda inBuf+1
           sta inPtr+1

                                ;spit out magic
           lda   #lz4fh_magic
           jsr   output_byte

                                ;loop invariant: check for end
compl      lda   inPtr+1
           cmp   inEnd+1
           bcc   compcont
           lda   inPtr
           cmp   inEnd
           bcc   compcont
           jmp   compdone

compcont
           jsr   findlongestmatch

           ; if (longestMatch < MIN_MATCH_LEN) {
           lda   longestmatch
           cmp   #MIN_MATCH_LEN
           bcs   compgoodmatch

           ; if (numLiterals == MAX_LITERAL_LEN) {
           lda   numliterals
           cmp   #MAX_LITERAL_LEN
           bne   compcheckfornoliterals

           ;       // We've maxed out the literal string length.  Emit
           ;       // the previously literals with an empty match indicator.
           ;       DBUG(("  max literals reached"));
           ;       *outPtr++ = 0xff;       // literal-len=15, match-len=15
           ;       *outPtr++ = MAX_LITERAL_LEN - INITIAL_LEN;  // 240
           ;       memcpy(outPtr, literalSrcPtr, numLiterals);
           ;       outPtr += numLiterals;
           ;       // Emit empty match indicator.
           ;       *outPtr++ = EMPTY_MATCH_TOKEN;
           ;       // Reset literal len, continue.
           ;       numLiterals = 0;
           lda   #$ff
           jsr   output_byte
           lda   #MAX_LITERAL_LEN
           sec
           sbc   #INITIAL_LEN
           jsr   output_byte
           jsr   comp_memcpy

           lda   #EMPTY_MATCH_TOKEN
           jsr   output_byte

           lda   #0
           sta   numliterals

           ;   if (numLiterals == 0) {
           ;        // Start of run of literals.  Save pointer to data.
           ;        literalSrcPtr = inPtr;
           ;    }
compcheckfornoliterals
           lda numliterals
           bne compincliteral

           ; literalSrcPtr = inPtr;
           lda inPtr
           sta literalsrcptr
           lda inPtr+1
           sta literalsrcptr+1

           ; numLiterals++;
           ; inPtr++;

compincliteral
           inc numliterals
           inc inPtr
           bne compl
           inc inPtr+1
           jmp compl

           ;} else {
           ;    // Good match found.
           ;    size_t adjustedMatch = longestMatch - MIN_MATCH_LEN;
           ;    // Start by emitting the 4/4 length byte.
           ;    uint8_t mixedLengths;
           ;    if (adjustedMatch <= INITIAL_LEN) {
           ;        mixedLengths = adjustedMatch;
           ;    } else {
           ;        mixedLengths = INITIAL_LEN;
           ;    }
           ;    if (numLiterals <= INITIAL_LEN) {
           ;        mixedLengths |= numLiterals << 4;
           ;    } else {
           ;        mixedLengths |= INITIAL_LEN << 4;
           ;    }
           ;    DBUG(("  match len=%zd off=0x%04zx lits=%zd mix=0x%02x\n",
           ;        longestMatch, matchOffset, numLiterals,
           ;        mixedLengths));
           ;    *outPtr++ = mixedLengths;
           ;    // Output the literals, starting with the extended length.
           ;    if (numLiterals >= INITIAL_LEN) {
           ;        *outPtr++ = numLiterals - INITIAL_LEN;
           ;    }
           ;    memcpy(outPtr, literalSrcPtr, numLiterals);
           ;    outPtr += numLiterals;
           ;    numLiterals = 0;
           ;    literalSrcPtr = NULL;       // debug/sanity check
           ;    // Now output the match, starting with the extended length.
           ;    if (adjustedMatch >= INITIAL_LEN) {
           ;        *outPtr++ = adjustedMatch - INITIAL_LEN;
           ;    }
           ;    *outPtr++ = matchOffset & 0xff;
           ;    *outPtr++ = (matchOffset >> 8) & 0xff;
           ;    inPtr += longestMatch;

compgoodmatch
           lda    longestmatch
           sec
           sbc    #MIN_MATCH_LEN
           sta    adjustedmatch
           cmp    #INITIAL_LEN
           beq    compsetmixedlen_am
           bcs    compsetmixedlen_initial

compsetmixedlen_am
           sta    mixedlengths
           bcc    compchecknumliterals      ; (cf=0)
compsetmixedlen_initial
           lda    #INITIAL_LEN
           sta    mixedlengths
compchecknumliterals
           lda    numliterals
           cmp    #INITIAL_LEN
           beq    compml_nlsh4
           bcs    compnumliterals_ilsh4
compml_nlsh4
           lda    numliterals
           asl
           asl
           asl
           asl
           ora    mixedlengths
           sta    mixedlengths
           jmp    compoutputmixedlengths
compnumliterals_ilsh4
           lda    mixedlengths
           ora    #INITIAL_LEN_SH4
           sta    mixedlengths

compoutputmixedlengths
           jsr    output_byte     ; a holds mixedlengths
           ;    if (numLiterals >= INITIAL_LEN) {
           ;        *outPtr++ = numLiterals - INITIAL_LEN;
           ;    }
           lda    numliterals
           cmp    #INITIAL_LEN
           bcc    comp_copy
           sbc    #INITIAL_LEN    ; (cf=1)
           jsr    output_byte

           ;    memcpy(outPtr, literalSrcPtr, numLiterals);
           ;    outPtr += numLiterals;
comp_copy
           jsr   comp_memcpy

           ;   numLiterals = 0;
           ;   literalSrcPtr = NULL;       // debug/sanity check
           lda    #0
           sta    numliterals
           sta    literalsrcptr
           sta    literalsrcptr+1

           ;   if (adjustedMatch >= INITIAL_LEN) {
           ;       *outPtr++ = adjustedMatch - INITIAL_LEN;
           ;   }
           lda    adjustedmatch
           cmp    #INITIAL_LEN
           bcc    comp_writematchoffset
           sbc    #INITIAL_LEN     ; (cf=1)
           jsr    output_byte

           ;   *outPtr++ = matchOffset & 0xff;
           ;   *outPtr++ = (matchOffset >> 8) & 0xff;
           ;   inPtr += longestMatch;
comp_writematchoffset
           lda    matchoffset
           jsr    output_byte
           lda    matchoffset+1
           jsr    output_byte
           lda    inPtr
           clc
           adc    longestmatch
           sta    inPtr
           lda    inPtr+1
           adc    #0
           sta    inPtr+1
           jmp    compl


           ;    // Dump any remaining literals, with the end-of-data indicator
           ;    // in the match len.
           ;    if (numLiterals <= INITIAL_LEN) {
           ;        *outPtr++ = (numLiterals << 4) | 0x0f;
           ;    } else {
           ;        *outPtr++ = 0xff;
           ;        *outPtr++ = numLiterals - INITIAL_LEN;
           ;    }
           ;    memcpy(outPtr, literalSrcPtr, numLiterals);
           ;    outPtr += numLiterals;

           ;    *outPtr++ = EOD_MATCH_TOKEN;

           ;    return outPtr - outBuf;

compdone
           lda   numliterals
           cmp   #INITIAL_LEN
           bcc   compdone_dumpnumlit
           beq   compdone_dumpnumlit

           lda   #$ff
           jsr   output_byte
           lda   numliterals
           sec
           sbc   #INITIAL_LEN
           jsr   output_byte
           jmp   compexit
           ; *outPtr++ = (numLiterals << 4) | 0x0f;

compdone_dumpnumlit
           lda   numliterals
           asl
           asl
           asl
           asl
           ora   #$0f
           jsr   output_byte

compexit
           jsr   comp_memcpy
           lda   #EOD_MATCH_TOKEN
           jsr   output_byte

                                    ; save output
           lda   outPtr
           sta   outEnd
           lda   outPtr+1
           sta   outEnd+1

           jmp   comp_restorezp   ;put zero page back

* output_byte
*
* Entry: a = byte
*        outPtr set
* Exit: outPtr incremented
* Uses: a, y
*
output_byte
           ldy #0
           sta (outPtr),y
           inc outPtr
           bne ob_exit
           inc outPtr+1

ob_exit  rts

* findlongestmatch
*
* Entry: inBuf set
*        in_buf set
*        inPtr set
*        inLen set
* Exit:  matchoffset ptr set
* Uses:  maxstartoffset
findlongestmatch
         ;  size_t findLongestMatch(const uint8_t* matchPtr, const uint8_t* inBuf,
         ;      size_t inLen, size_t* pMatchOffset)
         ;  {
         ;      size_t maxStartOffset = matchPtr - inBuf;
         ;      size_t longest = 0;
         ;      size_t longestOffset = 0;

                                  ;calculate end for loop invariant
           lda inPtr
           sta matchptr
           sec
           sbc inBuf
           sta maxstartoffset
           lda inPtr+1
           sta matchptr+1
           sbc inBuf+1
           sta maxstartoffset+1
                                 ;clear longest and longest match offset
           lda #0
           sta longest
           sta longestmatch
           sta longestoffset
           sta longestoffset+1
           sta ii
           sta ii+1

                                 ;loop through buffer, looking for matches

         ; for (size_t ii = 0; ii < maxStartOffset; ii++) {
flml       lda   ii+1
           cmp   maxstartoffset+1
           bcc   flm_lcont
           lda   ii
           cmp   maxstartoffset
           bcs   flm_done

flm_lcont
         ; size_t maxMatchLen = inLen - (matchPtr - inBuf);
           lda   matchptr
           sec
           sbc   inBuf
           sta   T0
           lda   matchptr+1
           sbc   inBuf+1
           sta   T0+1
           lda   inLen
           sec
           sbc   T0
           sta   maxmatchlen
           lda   inLen+1
           sbc   T0+1
           sta   maxmatchlen+1

         ; if (maxMatchLen > MAX_MATCH_LEN) {
         ;    maxMatchLen = MAX_MATCH_LEN;
         ; }
           lda   maxmatchlen+1              ; if MSB is set at all, maxmatchlen too big
           bne   flm_clampmaxmatchlen
           lda   maxmatchlen
           cmp   #MAX_MATCH_LEN
           bcc   flm_noverflow

flm_clampmaxmatchlen
           lda   #MAX_MATCH_LEN
           sta   maxmatchlen
           lda   #0
           sta   maxmatchlen+1

         ; if (maxMatchLen < MIN_MATCH_LEN) {
         ;   // too close to end of buffer, no point continuing
         ;   break;

flm_noverflow
           lda   maxmatchlen
           cmp   #MIN_MATCH_LEN
           bcc   flm_done

         ; size_t matchLen = getMatchLen(matchPtr, inBuf + ii, maxMatchLen);
         ; T0 will hold "inBuf + ii"
           lda   ii
           clc
           adc   inBuf
           sta   T0
           lda   ii+1
           adc   inBuf+1
           sta   T0+1
           jsr   getmatchlen

         ; if (matchLen > longest) {
         ;           longest = matchLen;
         ;           longestOffset = ii;
         ;       }
           lda   matchlen
           cmp   longest
           bcc   flm_checkmaxlen
           beq   flm_checkmaxlen

           sta   longest
           sta   longestmatch
           lda   ii
           sta   longestoffset
           lda   ii+1
           sta   longestoffset+1

         ; if (matchLen == maxMatchLen) {
         ;           // Not going to find a longer one -- any future matches
         ;           // will be the same length or shorter.
         ;           break;

flm_checkmaxlen
           lda   matchlen
           cmp   #MAX_MATCH_LEN
           beq   flm_done

         ; increment ii
           inc   ii
           bne   flml
           inc   ii+1
           jmp   flml

         ; *pMatchOffset = longestOffset;
         ; return longest;

flm_done   lda longestoffset
           sta matchoffset
           lda longestoffset+1
           sta matchoffset+1

           rts

* getmatchlen
* Entry: matchptr set
*        inBuf set
*        T0 set to inBuf + ii
*        maxmatchlen set
* Exit:  matchlen set
getmatchlen
         ; size_t getMatchLen(const uint8_t* str1, const uint8_t* str2, size_t count)
         ; {
         ;     size_t matchLen = 0;
         ;     while (count-- && *str1++ == *str2++) {
         ;         matchLen++;
         ;     }
         ;     return matchLen;
         ; }
           ldy #0
gmll
           lda (matchptr),y
           cmp (T0),y
           bne gml_done
           iny
           bne gmll

           ldy #MAX_MATCH_LEN
gml_done
           sty matchlen
           rts

* comp_memcpy
* Entry: outPtr
* Exit:  update outPtr
comp_memcpy
         ;    memcpy(outPtr, literalSrcPtr, numLiterals);
         ;    outPtr += numLiterals;
           ldy #0
cml
           lda (literalsrcptr),y
           sta (outPtr),y
           iny
           cpy numliterals
           bne cml

           sty T0

           lda outPtr
           clc
           adc T0
           sta outPtr
           lda outPtr+1
           adc #0
           sta outPtr+1
           rts


* comp_savezp
* saves off zero page that we will use
comp_savezp
           ldx    #31
cszpl      lda    $e0,x
           sta    comp_zpsavebuf,x
           dex
           bpl    cszpl
           rts

comp_zpsavebuf
           ds 16

* comp_restorezp
* restores zero page that we used
comp_restorezp
           ldx #31
cszpl      lda comp_zpsavebuf,x
           sta $e0,x
           dex
           bpl cszpl
           rts

