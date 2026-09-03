//============================================================================
// img_filter_def.v : external SPRAM configuration for IMG_FILTER
//
//  MEM_DWTH = 160 : one word holds one four-pixel beat (4 x 40-bit RGBA) of a
//                   single image row, i.e. exactly the four pixels that the
//                   four output lanes of one beat need from that row.
//  MEM_NUM  = 49  : the 49-tap window needs 48 stored rows plus one free bank
//                   to absorb the row that is streaming in, so 48 reads and
//                   1 write are issued in the same cycle.  Anything smaller
//                   cannot sustain 4 pixel/cycle at blk_v = 49.
//
//  Capacity used  : 49 banks x 360 words (img_width = 1440) of 1440 available.
//  Bandwidth used : blk_v accesses/cycle - the read enables follow the
//                   coefficient vector, so a small blk_v costs proportionally
//                   fewer accesses.
//============================================================================
`ifndef IMG_FILTER_DEF_V
`define IMG_FILTER_DEF_V

`define MEM_NUM  49
`define MEM_DWTH 160

`endif
