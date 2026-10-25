
#ifndef GGML_METAL_IMPL
#define GGML_METAL_IMPL

// kernel parameters for mat-mat threadgroups
//
// TODO: become function constants

#define SZ_SIMDGROUP 16
#define N_MM_NK 2
#define N_MM_NK_TOTAL (SZ_SIMDGROUP * N_MM_NK)

#define N_MM_BLOCK_X 4
#define N_MM_BLOCK_Y 2
#define N_MM_SIMD_GROUP_X 2
#define N_MM_SIMD_GROUP_Y 2

#define N_MM_NPART_AMAX 256

// kernel parameters for mat-vec threadgroups
//
// N_R0: number of src0 rows to process per simdgroup
// N_SG: number of simdgroups per threadgroup
//
// TODO: for optimal performance, become function of the device and work size

#define N_R0_Q1_0 8
#define N_SG_Q1_0 2

#define N_R0_Q2_0 8
#define N_SG_Q2_0 2

#define N_R0_Q4_0 4
#define N_SG_Q4_0 2

#define N_R0_Q4_1 4
#define N_SG_Q4_1 2

#define N_R0_Q5_0 4
#define N_SG_Q5_0 2

#define N_R0_Q5_1 4
#define N_SG_Q5_1 2

#define N_R0_Q8_0 2
#define N_SG_Q8_0 4

#define N_R0_MXFP4 2
#define N_SG_MXFP4 2

#define N_R0_Q2_K 4
#define N_SG_Q2_K 2

#define N_R0_Q3_K 2
#define N_SG_Q3_K 2

#define N_R0_Q4_K 2
#define N_SG_Q4_K 2

#define N_R0_Q5_K 1
#define N_SG_Q5_K 2

#define N_R0_Q6_K 2
#define N_SG_Q6_K 2

#define N_R0_IQ1_S 4
#define N_SG_IQ1_S 2
#define N_R0_IQ1_S_SPLIT 8

#define N_R0_IQ1_M 4
#define N_SG_IQ1_M 2
#define N_R0_IQ1_M_SPLIT 8

#define N_R0_IQ2_XXS 4
#define N_SG_IQ2_XXS 2
#define N_R0_IQ2_XXS_SPLIT 8

#define N_R0_IQ2_XS 4
#define N_SG_IQ2_XS 2
#define N_R0_IQ2_XS_SPLIT 8

#define N_R0_IQ2_S 4
#define N_SG_IQ2_S 2
#define N_R0_IQ2_S_SPLIT 8

#define N_R0_IQ3_XXS 4
#define N_SG_IQ3_XXS 2
#define N_R0_IQ3_XXS_SPLIT 8

#define N_R0_IQ3_S 4
#define N_SG_IQ3_S 2
#define N_R0_IQ3_S_SPLIT 8

#define N_R0_IQ4_NL 2
#define N_SG_IQ4_NL 2

#define N_R0_IQ4_XS 2
#define N_SG_IQ4_XS 2

#define N_R0_TQ2_0 4
#define N_SG_TQ2_0 2

// function constants offsets
#define FC_FLASH_ATTN_EXT_PAD          100
#define FC_FLASH_ATTN_EXT_BLK          200
#define FC_FLASH_ATTN_EXT              300
#define FC_FLASH_ATTN_EXT_VEC          400
#define FC_FLASH_ATTN_EXT_VEC_REDUCE   500
#define FC_MUL_MV                      600
#define FC_MUL_MM                      700
#define FC_ROPE                        800
#define FC_SSM_CONV                    900
#define FC_SOLVE_TRI                   1000
#define FC_COUNT_EQUAL                 1100
#define FC_UNARY                       1200
#define FC_BIN                         1300
#define FC_SUM_ROWS                    1400
#define FC_UPSCALE                     1500
#define FC_GATED_DELTA_NET             1600
#define FC_NORM                        1700
#define FC_TOPK_MOE                    1800
#define FC_MOE_REDUCE                  1900
#define FC_DSV4_HC                     2000
#define FC_PAD                         2100
#define FC_FLASH_ATTN_EXT_TENSOR       2200
#define FC_LIGHTNING_INDEXER           2200
#define FC_MUL_MV_MMA                  2300

// op-specific constants
#define OP_FLASH_ATTN_EXT_NQPSG 8
#define OP_FLASH_ATTN_EXT_NCPSG 64

#define OP_FLASH_ATTN_EXT_TENSOR_NQPSG       32
#define OP_FLASH_ATTN_EXT_TENSOR_NQPSG_LARGE 16
#define OP_FLASH_ATTN_EXT_TENSOR_NCPSG       64
#define OP_FLASH_ATTN_EXT_TENSOR_NSG         8

#define OP_FLASH_ATTN_EXT_VEC_NQPSG 1
#define OP_FLASH_ATTN_EXT_VEC_NCPSG 32

#define OP_LIGHTNING_INDEXER_DK    128
#define OP_LIGHTNING_INDEXER_NHPTG   8
#define OP_LIGHTNING_INDEXER_NKPSG   8
#define OP_LIGHTNING_INDEXER_NSG     8
#define OP_LIGHTNING_INDEXER_NBPTG   8

#define OP_UNARY_NUM_SCALE      10
#define OP_UNARY_NUM_FILL       11
#define OP_UNARY_NUM_CLAMP      12
#define OP_UNARY_NUM_SQR        13
#define OP_UNARY_NUM_SQRT       14
#define OP_UNARY_NUM_SIN        15
#define OP_UNARY_NUM_COS        16
#define OP_UNARY_NUM_LOG        17
#define OP_UNARY_NUM_LEAKY_RELU 18

#define OP_UNARY_NUM_TANH        100
#define OP_UNARY_NUM_RELU        101
#define OP_UNARY_NUM_SIGMOID     102
#define OP_UNARY_NUM_GELU        103
#define OP_UNARY_NUM_GELU_ERF    104
#define OP_UNARY_NUM_GELU_QUICK  105
#define OP_UNARY_NUM_SILU        106
#define OP_UNARY_NUM_ELU         107
#define OP_UNARY_NUM_NEG         108
#define OP_UNARY_NUM_ABS         109
#define OP_UNARY_NUM_SGN         110
#define OP_UNARY_NUM_STEP        111
#define OP_UNARY_NUM_HARDSWISH   112
#define OP_UNARY_NUM_HARDSIGMOID 113
#define OP_UNARY_NUM_EXP         114
#define OP_UNARY_NUM_SOFTPLUS    115
#define OP_UNARY_NUM_EXPM1       116
#define OP_UNARY_NUM_FLOOR       117
#define OP_UNARY_NUM_CEIL        118
#define OP_UNARY_NUM_ROUND       119
#define OP_UNARY_NUM_TRUNC       120
#define OP_UNARY_NUM_XIELU       121

#define OP_SUM_ROWS_NUM_SUM_ROWS 10
#define OP_SUM_ROWS_NUM_MEAN     11

#define OP_SSM_SCAN_SSD_CS  64 // Metal-specific; Chunk Size; 64 is largest multiple of 8 (simdgroup tile) fitting into 32 KiB Metal threadgroup mem limit (~26.75 KiB shared mem; see smem layout comment in kernel_ssm_scan_ssd_mma_f32)
#define OP_SSM_SCAN_SSD_HD  64 // Metal-specific; Head Dim the MMA kernel is specialized for (Mamba-2); use_mma gates on d_inner == this
#define OP_SSM_SCAN_SSD_NSG 4  // Metal-specific; Number of SimdGroups per threadgroup; NSG*32 == threads dispatched per threadgroup

// kernel argument structs
//
// - element counters (e.g. ne00) typically use int32_t to reduce register usage
//   however, be careful from int overflows when using those in the kernel implementation
//
// - strides (e.g. nb00) use uint64_t

typedef struct {
    int32_t  ne00;
    int32_t  ne01;
    int32_t  ne02;
    int32_t  ne03;
    uint64_t nb00;
    uint64_t nb01;
    uint64_t nb02;
    uint64_t nb03;
    int32_t  ne10;
    int32_t  ne11;
    int32_t  ne12;
    int32_t  ne13;
    uint64_t nb10;
    uint64_t nb11;
    uint64_t nb12;
    uint64_t nb13;
    int32_t  ne0;
    int32_t  ne1;
    int32_t  ne2;
    int32_t  ne3;
    uint64_t nb0;
    uint64_t nb1;
    uint64_t nb2;
    uint64_t nb3;
    int32_t  dim;
    int32_t  nc0;
} ggml_metal_kargs_concat;

typedef struct {
    int32_t  ne00;
    int32_t  ne01;
    int32_t  ne02;
    int32_t  ne03;
    uint64_t nb00;
    uint64_t nb01;
    uint64_t nb02;
    uint64_t nb03;
    int32_t  ne0;
    int32_t  ne1;
    int32_t  ne2;
    int32_t  ne3;
    uint64_t nb0;
    uint64_t nb1;
    uint64_t nb2;
    uint64_t nb3;
    float    slope;
    float    scale;
    float    bias;
    float    val;
    float    min;
    float    max;
} ggml_metal_kargs_unary;

typedef struct {
    int32_t  ne00;
    int32_t  ne01;
    int32_t  ne02;
    int32_t  ne03;
    uint64_t nb00;
    uint64_t nb01;
    uint64_t nb02;
    uint64_t nb03;
    int32_t  ne10;
    int32_t  ne11;
    int32_t  ne12;
    int32_t  ne13;
    uint64_t nb10;
    uint64_t nb11;
    uint64_t nb12;
    uint64_t nb13;
    int32_t  ne0;
    int32_t  ne1;
    int32_t  ne2;
    int32_t  ne3;
    uint64_t nb0;
    uint64_t nb1;
    uint64_t nb2;
    uint64_t nb3;
    uint64_t offs;
    uint64_t o1[8];
} ggml_metal_kargs_bin;

typedef struct {
    int64_t ne0;
    int64_t ne1;
    size_t nb01;
    size_t nb02;
    size_t nb11;
    size_t nb21;
} ggml_metal_kargs_add_id;

typedef struct {
    int32_t  ne00;
    int32_t  ne01;
    int32_t  ne02;
    int32_t  ne03;
    uint64_t nb00;
    uint64_t nb01;
    uint64_t nb02;
    uint64_t nb03;
    int32_t  ne0;
    int32_t  ne1;
    int32_t  ne2;
    int32_t  ne3;
    uint64_t nb0;
    uint64_t nb1;
    uint64_t nb2;
    uint64_t nb3;
} ggml_metal_kargs_repeat;

typedef struct {
    int64_t  nk0;
    int64_t  ne00;
    int64_t  ne01;
    int64_t  ne02;
    int64_t  ne03;
    uint64_t nb00;
    uint64_t nb01;
    uint64_t nb02;
    uint64_t nb03;
    int64_t  ne0;
    int64_t  ne1;
    int64_t  ne2;
    int64_t  ne3;
    uint64_t nb0;
    uint64_t nb1;
    uint64_t nb2;
    uint64_t nb3;
} ggml_metal_kargs_cpy;

typedef struct {
    int64_t  ne10;
    int64_t  ne11;
    int64_t  ne12;
    uint64_t nb10;
    uint64_t nb11;
    uint64_t nb12;
    uint64_t nb13;
    uint64_t nb1;
    uint64_t nb2;
    uint64_t nb3;
    uint64_t offs;
    bool     inplace;
} ggml_metal_kargs_set;

typedef struct {
    int32_t  ne00;
    int32_t  ne01;
    int32_t  ne02;
    int32_t  ne03;
    uint64_t nb00;
    uint64_t nb01;
    uint64_t nb02;
    uint64_t nb03;
    int32_t  ne0;
    int32_t  ne1;
    int32_t  ne2;
    int32_t  ne3;
    uint64_t nb0;
    uint64_t nb1;
    uint64_t nb2;
    uint64_t nb3;
    int32_t  n_past;
    int32_t  n_dims;
    int32_t  n_offs;
    int32_t  n_ctx_orig;
    float    freq_base;
    float    freq_scale;
    float    ext_factor;
    float    attn_factor;
    float    beta_fast;
    float    beta_slow;
    int32_t  sect_0;
    int32_t  sect_1;
    int32_t  sect_2;
    int32_t  sect_3;
    bool     src2;
    bool     inplace;
} ggml_metal_kargs_rope;

typedef struct {
    int32_t  ne0;
    int32_t  ne1;
    int32_t  ne2;
    int32_t  ne3;
    uint64_t nb0;
    uint64_t nb1;
    uint64_t nb2;
    uint64_t nb3;
    int32_t  nblocks;
} ggml_metal_kargs_flash_attn_ext_kv_f16;

typedef struct {
    int32_t  ne11;
    int32_t  ne_12_2; // assume K and V are same shape
    int32_t  ne_12_3;
    uint64_t nb11;
    uint64_t nb12;
    uint64_t nb13;
    uint64_t nb21;
    uint64_t nb22;
    uint64_t nb23;
    int32_t  ne31;
    int32_t  ne32;
    int32_t  ne33;
    uint64_t nb31;
    uint64_t nb32;
    uint64_t nb33;
} ggml_metal_kargs_flash_attn_ext_pad;

typedef struct {
    int32_t  ne01;
    int32_t  ne30;
    int32_t  ne31;
    int32_t  ne32;
    int32_t  ne33;
    uint64_t nb31;
    uint64_t nb32;
    uint64_t nb33;
} ggml_metal_kargs_flash_attn_ext_blk;

typedef struct {
    int32_t  ne01;
    int32_t  ne02;
    int32_t  ne03;
    uint64_t nb01;
    uint64_t nb02;
    uint64_t nb03;
    int32_t  ne11;
    int32_t  ne_12_2; // assume K and V are same shape
    int32_t  ne_12_3;
    int32_t  ns10;
    uint64_t nb11;
    uint64_t nb12;
    uint64_t nb13;
    int32_t  ns20;
    uint64_t nb21;
    uint64_t nb22;
    uint64_t nb23;
    int32_t  ne31;
    int32_t  ne32;
    int32_t  ne33;
    uint64_t nb31;
    uint64_t nb32;
    uint64_t nb33;
    int32_t  ne1;
    int32_t  ne2;
    int32_t  ne3;
    float    scale;
    float    max_bias;
    float    m0;
    float    m1;
    int32_t  n_head_log2;
    float    logit_softcap;
} ggml_metal_kargs_flash_attn_ext;

typedef struct {
    int32_t  ne01;
    int32_t  ne02;
    int32_t  ne03;
    uint64_t nb01;
    uint64_t nb02;
    uint64_t nb03;
    int32_t  ne11;
    int32_t  ne_12_2; // assume K and V are same shape
    int32_t  ne_12_3;
    int32_t  ns10;
    uint64_t nb11;
    uint64_t nb12;
    uint64_t nb13;
    int32_t  ns20;
    uint64_t nb21;
    uint64_t nb22;
    uint64_t nb23;
    int32_t  ne31;
    int32_t  ne32;
    int32_t  ne33;
    uint64_t nb31;
    uint64_t nb32;
    uint64_t nb33;
    int32_t  ne1;
    int32_t  ne2;
    int32_t  ne3;
    float    scale;
    float    max_bias;
    float    m0;
    float    m1;
    int32_t  n_head_log2;
    float    logit_softcap;
    int32_t  n_kv_max_padded;
} ggml_metal_kargs_flash_attn_ext_vec;

typedef struct {
    int32_t  ne30;
    int32_t  ne31;
    int32_t  ne32;
    int32_t  ne33;
    uint64_t nb31;
    uint64_t nb32;
    uint64_t nb33;
    int32_t  n_kv_max;
    int32_t  n_kv_max_padded;
} ggml_metal_kargs_flash_attn_ext_vec_idx;

typedef struct {
    int32_t  nrows;
} ggml_metal_kargs_flash_attn_ext_vec_reduce;

typedef struct {
    int32_t  ne00;
    int32_t  ne02;
    uint64_t nb01;
    uint64_t nb02;
    uint64_t nb03;
    int32_t  ne12;
    uint64_t nb10;
    uint64_t nb11;
    uint64_t nb12;
    uint64_t nb13;
    int32_t  ne0;
    int32_t  ne1;
    int16_t  r2;
    int16_t  r3;
} ggml_metal_kargs_mul_mm;

typedef struct {
    int32_t  ne00;
    int32_t  ne01;
    int32_t  ne02;
    uint64_t nb00;
    uint64_t nb01;
    uint64_t nb02;
    uint64_t nb03;
    int32_t  ne10;
    int32_t  ne11;
    int32_t  ne12;
    uint64_t nb10;
    uint64_t nb11;
    uint64_t nb12;
    uint64_t nb13;
    int32_t  ne0;
    int32_t  ne1;
    int32_t  nr0;
    int16_t  r2;
    int16_t  r3;
} ggml_metal_kargs_mul_mv;

typedef struct {
    int32_t  ne00;
    int32_t  ne01;
    int32_t  ne02;
    uint64_t nb00;
    uint64_t nb01;
    uint64_t nb02;
    uint64_t nb03;
    int32_t  ne10;
    int32_t  ne11;
    int32_t  ne12;
    uint64_t nb10;
    uint64_t nb11;
    uint64_t nb12;
    uint64_t nb13;
    int32_t  ne0;
    int32_t  ne1;
    int16_t  r2;
    int16_t  r3;
} ggml_metal_kargs_mul_mv_ext;

typedef struct {
    int32_t  ne02;
    int32_t  ne10;
    int32_t  ne11;  // n_expert_used (bcast)
    uint64_t nb11;
    uint64_t nb12;
    int32_t  ne21; // n_tokens
    int32_t  ne20;  // n_expert_used
    uint64_t nb21;
} ggml_metal_kargs_mul_mm_id_map0;

typedef struct {
    int32_t  ne00;
    int32_t  ne01;
    int32_t  ne02;
    uint64_t nb01;
    uint64_t nb02;
} ggml_metal_kargs_mul_mm_id_amax;

typedef struct {
    int32_t  ne00;
    int32_t  ne02;
    uint64_t nb01;
    uint64_t nb02;
    uint64_t nb03;
    int32_t  ne11;
    uint64_t nb10;
    uint64_t nb11;
    uint64_t nb12;
    uint64_t nb13;
    int32_t  ne20;
    int32_t  ne21;
    int32_t  ne0;
    int32_t  ne1;
    int16_t  r2;
    int16_t  r3;
} ggml_metal_kargs_mul_mm_id;

typedef struct {
    int32_t  nei0;
    int32_t  nei1;
    uint64_t nbi1;
    int32_t  ne00;
    int32_t  ne01;
    int32_t  ne02;
    uint64_t nb00;
    uint64_t nb01;
    uint64_t nb02;
    int32_t  ne10;
    int32_t  ne11;
    int32_t  ne12;
    int32_t  ne13;
    uint64_t nb10;
    uint64_t nb11;
    uint64_t nb12;
    int32_t  ne0;
    int32_t  ne1;
    uint64_t nb1;
    int32_t  nr0;
} ggml_metal_kargs_mul_mv_id;

// NORM
// RMS_NORM
typedef struct {
    int32_t  ne00;
    int32_t  ne00_t;
    uint64_t nb1;
    uint64_t nb2;
    uint64_t nb3;
    float    eps;
    int32_t  nef1[3];
    int32_t  nef2[3];
    int32_t  nef3[3];
    uint64_t nbf1[3];
    uint64_t nbf2[3];
    uint64_t nbf3[3];
    float    scale;
} ggml_metal_kargs_norm;

typedef struct {
    int32_t  ne00;
    int32_t  ne01;
    int32_t  ne02;
    int32_t  ne03;
    uint64_t nb00;
    uint64_t nb01;
    uint64_t nb02;
    uint64_t nb03;
    int32_t  ne0;
    int32_t  ne1;
    int32_t  ne2;
    int32_t  ne3;
    uint64_t nb0;
    uint64_t nb1;
    uint64_t nb2;
    uint64_t nb3;
    float    eps;
} ggml_metal_kargs_l2_norm;

typedef struct {
    int64_t  ne00;
    int64_t  ne01;
    int64_t  ne02;
    uint64_t nb00;
    uint64_t nb01;
    uint64_t nb02;
    int32_t  ngrp;
    float    eps;
} ggml_metal_kargs_group_norm;

typedef struct {
    int32_t  IC;
    int32_t  IL;
    int32_t  K;
    int32_t  s0;
    uint64_t nb0;
    uint64_t nb1;
} ggml_metal_kargs_conv_transpose_1d;

typedef struct {
    int32_t  T_in;
    int32_t  T_out;
    int32_t  OC;
    int32_t  K;
    int32_t  K_OC;
    int32_t  s0;
    int32_t  p0;
} ggml_metal_kargs_col2im_1d;

typedef struct {
    int32_t T;
    int32_t C;
} ggml_metal_kargs_snake;

typedef struct {
    int32_t  IC;
    int32_t  IH;
    int32_t  IW;
    int32_t  KH;
    int32_t  KW;
    int32_t  OC;
    int32_t  s0;
    uint64_t nb0;
    uint64_t nb1;
    uint64_t nb2;
    uint64_t nb3;
} ggml_metal_kargs_conv_transpose_2d;

typedef struct {
    uint64_t nb00;
    uint64_t nb01;
    uint64_t nb02;
    uint64_t nb03;
    uint64_t nb10;
    uint64_t nb11;
    uint64_t nb12;
    uint64_t nb13;
    uint64_t nb0;
    uint64_t nb1;
    uint64_t nb2;
    uint64_t nb3;
    int32_t  IW;
    int32_t  IH;
    int32_t  KW;
    int32_t  KH;
    int32_t  IC;
    int32_t  OC;
    int32_t  OW;
    int32_t  OH;
    int32_t  N;
    int32_t  s0;
    int32_t  s1;
    int32_t  p0;
    int32_t  p1;
    int32_t  d0;
    int32_t  d1;
} ggml_metal_kargs_conv_2d;

typedef struct {
    uint64_t nb00;  // kernel strides
    uint64_t nb01;
    uint64_t nb02;
    uint64_t nb10;  // input strides
    uint64_t nb11;
    uint64_t nb12;
    uint64_t nb13;
    uint64_t nb0;   // output strides
    uint64_t nb1;
    uint64_t nb2;
    uint64_t nb3;
    int32_t  IW;    // input width
    int32_t  IH;    // input height
    int32_t  KW;    // kernel width
    int32_t  KH;    // kernel height
    int32_t  C;     // channels (IC == OC for depthwise)
    int32_t  OW;    // output width
    int32_t  OH;    // output height
    int32_t  N;     // batch size
    int32_t  s0;    // stride x
    int32_t  s1;    // stride y
    int32_t  p0;    // padding x
    int32_t  p1;    // padding y
    int32_t  d0;    // dilation x
    int32_t  d1;    // dilation y
} ggml_metal_kargs_conv_2d_dw;

typedef struct {
    uint64_t  ofs0;
    uint64_t  ofs1;
    int32_t  IW;
    int32_t  IH;
    int32_t  CHW;
    int32_t  s0;
    int32_t  s1;
    int32_t  p0;
    int32_t  p1;
    int32_t  d0;
    int32_t  d1;
    int32_t  N;
    int32_t  KH;
    int32_t  KW;
    int32_t  KHW; // KH * KW, pre-computed on CPU to save GPU resources
} ggml_metal_kargs_im2col;

typedef struct {
    int32_t  IW;
    int32_t  IH;
    int32_t  ID;
    int32_t  OW;
    int32_t  OH;
    int32_t  OD;
    int32_t  KW;
    int32_t  KH;
    int32_t  KD;
    int32_t  s0;
    int32_t  s1;
    int32_t  s2;
    int32_t  p0;
    int32_t  p1;
    int32_t  p2;
    int32_t  d0;
    int32_t  d1;
    int32_t  d2;
    int32_t  IC;
    int32_t  N;
    int32_t  OC;
    uint64_t nb00;
    uint64_t nb01;
    uint64_t nb02;
    uint64_t nb03;
    uint64_t nb10;
    uint64_t nb11;
    uint64_t nb12;
    uint64_t nb13;
    uint64_t nb0;
    uint64_t nb1;
    uint64_t nb2;
    uint64_t nb3;
} ggml_metal_kargs_conv_3d;

typedef struct{
    int32_t  ne00;
    uint64_t nb01;
    int32_t  ne10;
    uint64_t nb11;
    int32_t  ne0;
    uint64_t nb1;
    int32_t  i00;
    int32_t  i10;
    float    alpha;
    float    limit;
} ggml_metal_kargs_glu;

typedef struct {
    uint64_t np;
} ggml_metal_kargs_sum;

typedef struct {
    int64_t  ne00;
    int64_t  ne01;
    int64_t  ne02;
    int64_t  ne03;
    uint64_t nb00;
    uint64_t nb01;
    uint64_t nb02;
    uint64_t nb03;
    int64_t  ne0;
    int64_t  ne1;
    int64_t  ne2;
    int64_t  ne3;
    uint64_t nb0;
    uint64_t nb1;
    uint64_t nb2;
    uint64_t nb3;
} ggml_metal_kargs_sum_rows;

typedef struct {
    int64_t  ne00;
    int64_t  ne01;
    int64_t  ne02;
    int64_t  ne03;
    uint64_t nb00;
    uint64_t nb01;
    uint64_t nb02;
    uint64_t nb03;
    int64_t  net0;
    int64_t  net1;
    int64_t  net2;
    int64_t  net3;
    uint64_t nbt0;
    uint64_t nbt1;
    uint64_t nbt2;
    uint64_t nbt3;
    bool     outb;
} ggml_metal_kargs_cumsum_blk;

typedef struct {
    int64_t  ne00;
    int64_t  ne01;
    int64_t  ne02;
    int64_t  ne03;
    uint64_t nb00;
    uint64_t nb01;
    uint64_t nb02;
    uint64_t nb03;
    int64_t  net0;
    int64_t  net1;
    int64_t  net2;
    int64_t  net3;
    uint64_t nbt0;
    uint64_t nbt1;
    uint64_t nbt2;
    uint64_t nbt3;
} ggml_metal_kargs_cumsum_add;

typedef struct {
    int32_t  ne00;
    int32_t  ne01;
    int32_t  ne02;
    uint64_t nb01;
    uint64_t nb02;
    uint64_t nb03;
    int32_t  ne11;
    int32_t  ne12;
    int32_t  ne13;
    uint64_t nb11;
    uint64_t nb12;
    uint64_t nb13;
    uint64_t nb1;
    uint64_t nb2;
    uint64_t nb3;
    float    scale;
    float    max_bias;
    float    m0;
    float    m1;
    int32_t  n_head_log2;
} ggml_metal_kargs_soft_max;

typedef struct {
    int64_t  ne00;
    int64_t  ne01;
    int64_t  ne02;
    uint64_t nb00;
    uint64_t nb01;
    uint64_t nb02;
    int64_t  ne11;
    uint64_t nb10;
    uint64_t nb11;
    int64_t  ne0;
    int64_t  ne1;
    int64_t  ne2;
    uint64_t nb0;
    uint64_t nb1;
    uint64_t nb2;
} ggml_metal_kargs_ssm_conv;

typedef struct {
    int64_t  d_state;
    int64_t  d_inner;
    int64_t  n_head;
    int64_t  n_group;
    int64_t  n_seq_tokens;
    int64_t  n_seq_tokens_total;
    int64_t  token_offset;
    int64_t  n_seqs;
    int64_t  K;
    uint64_t s_off;
    uint64_t nb00;
    uint64_t nb01;
    uint64_t nb02;
    uint64_t nb03;
    uint64_t nb10;
    uint64_t nb11;
    uint64_t nb12;
    uint64_t ns12;
    uint64_t nb13;
    uint64_t nb20;
    uint64_t nb21;
    uint64_t ns21;
    uint64_t nb22;
    int64_t  ne30;
    uint64_t nb31;
    uint64_t nb41;
    uint64_t nb42;
    uint64_t ns42;
    uint64_t nb43;
    uint64_t nb51;
    uint64_t nb52;
    uint64_t ns52;
    uint64_t nb53;
    uint64_t nb0;
} ggml_metal_kargs_ssm_scan;

typedef struct {
    int32_t  ne00;
    int32_t  ne01;
    int32_t  ne02;
    int32_t  ne03;
    uint64_t nb00;
    uint64_t nb01;
    uint64_t nb02;
    uint64_t nb03;
    int32_t  ne10;
    int32_t  ne11;
    int32_t  ne12;
    int32_t  ne13;
    uint64_t nb10;
    uint64_t nb11;
    uint64_t nb12;
    uint64_t nb13;
    int32_t  ne20;
    int32_t  ne21;
    int32_t  ne22;
    int32_t  ne23;
    uint64_t nb20;
    uint64_t nb21;
    uint64_t nb22;
    uint64_t nb23;
    int32_t  ns02;
    int32_t  ns12;
    int32_t  ns22;
    int32_t  ne0;
    int32_t  ne1;
    int32_t  ne2;
    int32_t  ne3;
    uint64_t nb0;
    uint64_t nb1;
    uint64_t nb2;
    uint64_t nb3;
    uint64_t nb_out; // 0 => snapshots are appended after the attn scores (unfused)
} ggml_metal_kargs_gated_delta_net;

typedef struct {
    int32_t  ne00;
    int32_t  ne01;
    int32_t  ne02;
    int32_t  ne03;
    uint64_t nb00;
    uint64_t nb01;
    uint64_t nb02;
    uint64_t nb03;
    int32_t  ne10;
    int32_t  ne11;
    int32_t  ne12;
    int32_t  ne13;
    uint64_t nb10;
    uint64_t nb11;
    uint64_t nb12;
    uint64_t nb13;
    int32_t  ne0;
    int32_t  ne1;
    int32_t  ne2;
    int32_t  ne3;
    uint64_t nb0;
    uint64_t nb1;
    uint64_t nb2;
    uint64_t nb3;
} ggml_metal_kargs_solve_tri;

typedef struct {
    int32_t  ne00t;
    int32_t  ne00;
    uint64_t nb01;
    uint64_t nb02;
    uint64_t nb03;
    int32_t  ne10;
    uint64_t nb10;
    uint64_t nb11;
    uint64_t nb12;
    uint64_t nb1;
    uint64_t nb2;
    uint64_t nb3;
} ggml_metal_kargs_get_rows;

typedef struct {
    int32_t  nk0;
    int32_t  ne01;
    uint64_t nb01;
    uint64_t nb02;
    uint64_t nb03;
    int32_t  ne11;
    int32_t  ne12;
    uint64_t nb10;
    uint64_t nb11;
    uint64_t nb12;
    uint64_t nb1;
    uint64_t nb2;
    uint64_t nb3;
} ggml_metal_kargs_set_rows;

typedef struct {
    int32_t  ne00;
    int32_t  ne01;
    int32_t  ne02;
    int32_t  ne03;
    uint64_t nb00;
    uint64_t nb01;
    uint64_t nb02;
    uint64_t nb03;
    int32_t  ne0;
    int32_t  ne1;
    int32_t  ne2;
    int32_t  ne3;
    uint64_t nb0;
    uint64_t nb1;
    uint64_t nb2;
    uint64_t nb3;
} ggml_metal_kargs_diag;

typedef struct {
    int64_t  ne00;
    int64_t  ne01;
    int64_t  ne02;
    int64_t  ne03;
    uint64_t nb00;
    uint64_t nb01;
    uint64_t nb02;
    uint64_t nb03;
    int64_t  ne0;
    int64_t  ne1;
    int64_t  ne2;
    int64_t  ne3;
    uint64_t nb0;
    uint64_t nb1;
    uint64_t nb2;
    uint64_t nb3;
    float    sf0;
    float    sf1;
    float    sf2;
    float    sf3;
    float    poffs;
} ggml_metal_kargs_upscale;

typedef struct {
    int64_t  ne00;
    int64_t  ne01;
    int64_t  ne02;
    int64_t  ne03;
    uint64_t nb00;
    uint64_t nb01;
    uint64_t nb02;
    uint64_t nb03;
    int64_t  ne0;
    int64_t  ne1;
    int64_t  ne2;
    int64_t  ne3;
    uint64_t nb0;
    uint64_t nb1;
    uint64_t nb2;
    uint64_t nb3;
    int32_t  lp0;
    int32_t  lp1;
    int32_t  lp2;
    int32_t  lp3;
} ggml_metal_kargs_pad;

typedef struct {
    int64_t  ne00;
    int64_t  ne01;
    int64_t  ne02;
    int64_t  ne03;
    uint64_t nb00;
    uint64_t nb01;
    uint64_t nb02;
    uint64_t nb03;
    int64_t  ne0;
    int64_t  ne1;
    int64_t  ne2;
    int64_t  ne3;
    uint64_t nb0;
    uint64_t nb1;
    uint64_t nb2;
    uint64_t nb3;
    int32_t  p0;
    int32_t  p1;
} ggml_metal_kargs_pad_reflect_1d;

typedef struct {
    int64_t  ne00;
    int64_t  ne01;
    int64_t  ne02;
    int64_t  ne03;
    uint64_t nb00;
    uint64_t nb01;
    uint64_t nb02;
    uint64_t nb03;
    int64_t  ne0;
    int64_t  ne1;
    int64_t  ne2;
    int64_t  ne3;
    uint64_t nb0;
    uint64_t nb1;
    uint64_t nb2;
    uint64_t nb3;
    int32_t  s0;
    int32_t  s1;
    int32_t  s2;
    int32_t  s3;
} ggml_metal_kargs_roll;

typedef struct {
    uint64_t nb1;
    int      dim;
    int      max_period;
} ggml_metal_kargs_timestep_embedding;

typedef struct {
    int32_t  ne00;
    int32_t  ne01;
    int32_t  ne02;
    int32_t  ne03;
    uint64_t nb00;
    uint64_t nb01;
    uint64_t nb02;
    uint64_t nb03;
    int32_t  ne0;
    int32_t  ne1;
    int32_t  ne2;
    int32_t  ne3;
    uint64_t nb0;
    uint64_t nb1;
    uint64_t nb2;
    uint64_t nb3;
} ggml_metal_kargs_tri;

typedef struct {
    int32_t  ne00;
    int32_t  ne01;
    int32_t  ne02;
    int32_t  ne03;
    uint64_t nb00;
    uint64_t nb01;
    uint64_t nb02;
    uint64_t nb03;
    int32_t  ne0;
    int32_t  ne1;
    int32_t  ne2;
    int32_t  ne3;
    int32_t  top_k;
} ggml_metal_kargs_argsort;

typedef struct {
    int64_t  ne00;
    int64_t  ne01;
    int64_t  ne02;
    int64_t  ne03;
    uint64_t nb00;
    uint64_t nb01;
    uint64_t nb02;
    uint64_t nb03;
    int32_t  ne0;
    int32_t  ne1;
    int32_t  ne2;
    int32_t  ne3;
    int32_t  top_k;
    int32_t  len;
} ggml_metal_kargs_argsort_merge;

typedef struct {
    int32_t  ne00;   // number of columns (elements per row)
    int32_t  ne01;   // rows
    int32_t  ne02;
    int32_t  ne03;
    uint64_t nb01;   // row stride in src0
    uint64_t nb02;
    uint64_t nb03;
    int32_t  top_k;  // k
} ggml_metal_kargs_top_k;

// widths at or above this use the threadgroup FWHT kernel, one row per threadgroup
// with GGML_METAL_FWHT_TG_NT threads, instead of one row per simdgroup
#define GGML_METAL_FWHT_TG_MIN_N 512
#define GGML_METAL_FWHT_TG_NT    256

typedef struct {
    int32_t  ne01;      // n_tokens
    uint64_t nb01;      // logits row stride
    uint64_t nb1_ids;   // ids row stride
    float    clamp;
    float    scale;
} ggml_metal_kargs_topk_moe;

typedef struct {
    int32_t ne00; // n_embd
    int32_t ne02; // n_tokens
} ggml_metal_kargs_moe_reduce;

typedef struct {
    int32_t nrows;
} ggml_metal_kargs_fwht;

typedef struct {
    int64_t  ne0;
    float    start;
    float    step;
} ggml_metal_kargs_arange;

typedef struct {
    int64_t val;
} ggml_metal_kargs_memset;

typedef struct {
    int32_t  n_kv;
    int32_t  n_batch;
    int32_t  mask_ne3;
    uint64_t nb1;
    uint64_t nb3;
    uint64_t nbq1;
    uint64_t nbq2;
    uint64_t nbq3;
    uint64_t nbk2;
    uint64_t nbk3;
    uint64_t nbw1;
    uint64_t nbw3;
    uint64_t nbm1;
    uint64_t nbm3;
} ggml_metal_kargs_lightning_indexer;

typedef struct {
    int32_t  n_tokens;
    int32_t  n_iter;
    uint64_t nb_m0;
    uint64_t nb_m1;
    uint64_t nb_s0;
    uint64_t nb_b0;
    uint64_t nb_d0;
    uint64_t nb_d1;
    uint64_t nb_d2;
    float    eps;
} ggml_metal_kargs_dsv4_hc_comb;

typedef struct {
    int32_t  n_embd;
    int32_t  n_tokens;
    uint64_t nb_x0;
    uint64_t nb_x1;
    uint64_t nb_x2;
    uint64_t nb_w0;
    uint64_t nb_w1;
    uint64_t nb_w2;
    uint64_t nb_d0;
    uint64_t nb_d1;
    float    scale;
} ggml_metal_kargs_dsv4_hc_pre;

typedef struct {
    int32_t  n_embd;
    int32_t  n_tokens;
    uint64_t nb_x0;
    uint64_t nb_x1;
    uint64_t nb_r0;
    uint64_t nb_r1;
    uint64_t nb_r2;
    uint64_t nb_p0;
    uint64_t nb_p1;
    uint64_t nb_c0;
    uint64_t nb_c1;
    uint64_t nb_c2;
    uint64_t nb_d0;
    uint64_t nb_d1;
    uint64_t nb_d2;
} ggml_metal_kargs_dsv4_hc_post;

typedef struct {
    int32_t  ne00;
    int32_t  ne01;
    int32_t  ne02;
    int32_t  ne03;
    uint64_t nb00;
    uint64_t nb01;
    uint64_t nb02;
    uint64_t nb03;
    uint64_t nb10;
    uint64_t nb11;
    uint64_t nb12;
    uint64_t nb13;
} ggml_metal_kargs_count_equal;

typedef struct {
    int32_t  k0;
    int32_t  k1;
    int32_t  s0;
    int32_t  s1;
    int32_t  p0;
    int32_t  p1;
    int64_t  IH;
    int64_t  IW;
    int64_t  OH;
    int64_t  OW;
    int64_t  np;
} ggml_metal_kargs_pool_2d;

typedef struct {
    int32_t  k0;
    int32_t  s0;
    int32_t  p0;
    int64_t  IW;
    int64_t  OW;
    int64_t  np;
} ggml_metal_kargs_pool_1d;

typedef struct {
     int64_t ne00;
    uint64_t nb01;
} ggml_metal_kargs_argmax;

typedef struct {
    int64_t  np;
} ggml_metal_kargs_opt_step_adamw;

typedef struct {
    int64_t  np;
} ggml_metal_kargs_opt_step_sgd;

typedef struct {
    int64_t ne;
} ggml_metal_kargs_silu_back;

#endif // GGML_METAL_IMPL

#include <metal_stdlib>

#ifdef GGML_METAL_HAS_TENSOR
#include <metal_tensor>

#include <MetalPerformancePrimitives/MetalPerformancePrimitives.h>
#endif

using namespace metal;

#define MAX(x, y) ((x) > (y) ? (x) : (y))
#define MIN(x, y) ((x) < (y) ? (x) : (y))
#define SWAP(x, y) { auto tmp = (x); (x) = (y); (y) = tmp; }

#define PAD2(x, n) (((x) + (n) - 1) & ~((n) - 1))

#define FOR_UNROLL(x) _Pragma("clang loop unroll(full)") for (x)

#define N_SIMDWIDTH 32 // assuming SIMD group size is 32

// ref: https://developer.apple.com/metal/Metal-Shading-Language-Specification.pdf
//
// cmd:
//   .../usr/bin/metal -dM -E -c                             ggml/src/ggml-metal/kernels/<src>.metal
//   .../usr/bin/metal -dM -E -c -target air64-apple-ios14.0 ggml/src/ggml-metal/kernels/<src>.metal
//
#if __METAL_VERSION__ < 310 && defined(GGML_METAL_HAS_BF16)
#undef GGML_METAL_HAS_BF16
#endif

#if defined(GGML_METAL_HAS_BF16)
typedef matrix<bfloat, 4, 4> bfloat4x4;
typedef matrix<bfloat, 2, 4> bfloat2x4;
#endif

constexpr constant static float kvalues_iq4nl_f[16] = {
    -127.f, -104.f, -83.f, -65.f, -49.f, -35.f, -22.f, -10.f, 1.f, 13.f, 25.f, 38.f, 53.f, 69.f, 89.f, 113.f
};

constexpr constant static float kvalues_mxfp4_f[16] = {
    0, .5f, 1.f, 1.5f, 2.f, 3.f, 4.f, 6.f, -0, -.5f, -1.f, -1.5f, -2.f, -3.f, -4.f, -6.f
};

static inline int best_index_int8(int n, constant float * val, float x) {
    if (x <= val[0]) return 0;
    if (x >= val[n-1]) return n-1;
    int ml = 0, mu = n-1;
    while (mu-ml > 1) {
        int mav = (ml+mu)/2;
        if (x < val[mav]) mu = mav; else ml = mav;
    }
    return x - val[mu-1] < val[mu] - x ? mu-1 : mu;
}

static inline float e8m0_to_fp32(uint8_t x) {
    uint32_t bits;

    if (x == 0) {
        bits = 0x00400000;
    } else {
        bits = (uint32_t) x << 23;
    }

    return as_type<float>(bits);
}

static inline float dot(float x, float y) {
    return x*y;
}

static inline float sum(float x) {
    return x;
}

static inline float sum(float4 x) {
    return x[0] + x[1] + x[2] + x[3];
}

enum ggml_sort_order {
    GGML_SORT_ORDER_ASC,
    GGML_SORT_ORDER_DESC,
};

constant float GELU_COEF_A     = 0.044715f;
constant float GELU_QUICK_COEF = -1.702f;
constant float SQRT_2_OVER_PI  = 0.79788456080286535587989211986876f;
constant float SQRT_2_INV      = 0.70710678118654752440084436210484f;

// based on Abramowitz and Stegun formula 7.1.26 or similar Hastings' approximation
// ref: https://www.johndcook.com/blog/python_erf/
constant float p_erf  = 0.3275911f;
constant float a1_erf = 0.254829592f;
constant float a2_erf = -0.284496736f;
constant float a3_erf = 1.421413741f;
constant float a4_erf = -1.453152027f;
constant float a5_erf = 1.061405429f;

template<typename T>
inline T erf_approx(T x) {
    T sign_x = sign(x);
    x = fabs(x);
    T t = 1.0f / (1.0f + p_erf * x);
    T y = 1.0f - (((((a5_erf * t + a4_erf) * t) + a3_erf) * t + a2_erf) * t + a1_erf) * t * exp(-x * x);
    return sign_x * y;
}

template<typename T> T elu_approx(T x);

template<> inline float elu_approx<float>(float x) {
    return (x > 0.f) ? x : (exp(x) - 1);
}

template<> inline float4 elu_approx<float4>(float4 x) {
    float4 res;

    res[0] = (x[0] > 0.0f) ? x[0] : (exp(x[0]) - 1.0f);
    res[1] = (x[1] > 0.0f) ? x[1] : (exp(x[1]) - 1.0f);
    res[2] = (x[2] > 0.0f) ? x[2] : (exp(x[2]) - 1.0f);
    res[3] = (x[3] > 0.0f) ? x[3] : (exp(x[3]) - 1.0f);

    return res;
}

typedef void (im2col_t)(
        constant ggml_metal_kargs_im2col & args,
        device const float * x,
        device        char * dst,
        uint3 tgpig[[threadgroup_position_in_grid]],
        uint3  tgpg[[threadgroups_per_grid]],
        uint3 tpitg[[thread_position_in_threadgroup]],
        uint3   ntg[[threads_per_threadgroup]]);

template <typename T>
kernel void kernel_im2col(
        constant ggml_metal_kargs_im2col & args,
        device const float * x,
        device        char * dst,
        uint3 tgpig[[threadgroup_position_in_grid]],
        uint3  tgpg[[threadgroups_per_grid]],
        uint3 tpitg[[thread_position_in_threadgroup]],
        uint3   ntg[[threads_per_threadgroup]]) {
//    const int64_t IC = tgpg[0];
    const int64_t OH = tgpg[1];
    const int64_t OW = tgpg[2];

    const int64_t KH = ntg[1];
    const int64_t KW = ntg[2];

          int64_t in  = tpitg[0];
    const int64_t ikh = tpitg[1];
    const int64_t ikw = tpitg[2];

    const int64_t iic = tgpig[0];
    const int64_t ioh = tgpig[1];
    const int64_t iow = tgpig[2];

    const int64_t iiw = iow*args.s0 + ikw*args.d0 - args.p0;
    const int64_t iih = ioh*args.s1 + ikh*args.d1 - args.p1;

    int64_t offset_dst = (in*OH*OW + ioh*OW + iow)*args.CHW + (iic*(KH*KW) + ikh*KW + ikw);

    device T * pdst = (device T *) (dst);

    if (iih < 0 || iih >= args.IH || iiw < 0 || iiw >= args.IW) {
        while (in < args.N) {
            pdst[offset_dst] = 0.0f;
            offset_dst += ntg[0]*args.CHW*OH*OW;

            in += ntg[0];
        }
    } else {
        int64_t offset_src = in*args.ofs0 + iic*args.ofs1 + iih*args.IW + iiw;

        while (in < args.N) {
            pdst[offset_dst] = x[offset_src];

            offset_dst += ntg[0]*args.CHW*OH*OW;
            offset_src += ntg[0]*args.ofs0;

            in += ntg[0];
        }
    }
}

template [[host_name("kernel_im2col_f32")]] kernel im2col_t kernel_im2col<float>;
template [[host_name("kernel_im2col_f16")]] kernel im2col_t kernel_im2col<half>;

// TODO: optimize
typedef void (im2col_ext_t)(
        constant ggml_metal_kargs_im2col & args,
        device const float * x,
        device        char * dst,
        uint3 tgpig[[threadgroup_position_in_grid]],
        uint3  tgpg[[threadgroups_per_grid]],
        uint3 tpitg[[thread_position_in_threadgroup]],
        uint3   ntg[[threads_per_threadgroup]]);

template <typename T>
kernel void kernel_im2col_ext(
        constant ggml_metal_kargs_im2col & args,
        device const float * x,
        device        char * dst,
        uint3 tgpig[[threadgroup_position_in_grid]],
        uint3  tgpg[[threadgroups_per_grid]],      // tgpg[0] = D x IC x KH x KW, CHW = IC x KH x KW
        uint3 tpitg[[thread_position_in_threadgroup]],
        uint3   ntg[[threads_per_threadgroup]]) {  // [M, 1, 1]
    const int64_t KHW = (int64_t)args.KHW;

    const int64_t d   = tgpig[0] / args.CHW;
    const int64_t chw = tgpig[0] % args.CHW;
    const int64_t tgpig_0 = chw / KHW;  // 0 ~ (IC - 1)
    const int64_t HW = tgpig[0] % KHW;

    const int64_t tpitg_0 = (d * ntg[0]) + tpitg[0];
    if (tpitg_0 >= args.N) {
        return;
    }

    const int64_t tpitg_1 = HW / args.KW;
    const int64_t tpitg_2 = HW % args.KW;

    const int64_t iiw = tgpig[2] * args.s0 + tpitg_2 * args.d0 - args.p0;
    const int64_t iih = tgpig[1] * args.s1 + tpitg_1 * args.d1 - args.p1;

    const int64_t offset_dst =
        (tpitg_0 * tgpg[1] * tgpg[2] + tgpig[1] * tgpg[2] + tgpig[2]) * args.CHW +
        (tgpig_0 * KHW + tpitg_1 * args.KW + tpitg_2);

    device T * pdst = (device T *) (dst);

    if (iih < 0 || iih >= args.IH || iiw < 0 || iiw >= args.IW) {
        pdst[offset_dst] = 0.0f;
    } else {
        const int64_t offset_src = tpitg_0 * args.ofs0 + tgpig_0 * args.ofs1;
        pdst[offset_dst] = x[offset_src + iih * args.IW + iiw];
    }
}

template [[host_name("kernel_im2col_ext_f32")]] kernel im2col_ext_t kernel_im2col_ext<float>;
template [[host_name("kernel_im2col_ext_f16")]] kernel im2col_ext_t kernel_im2col_ext<half>;

template <typename T>
kernel void kernel_col2im_1d(
        constant ggml_metal_kargs_col2im_1d & args,
        device const T * col,
        device       T * dst,
        uint         tgpig [[threadgroup_position_in_grid]],
        uint         tpitg [[thread_position_in_threadgroup]],
        uint         ntg   [[threads_per_threadgroup]]) {

    const int idx = tgpig * ntg + tpitg;
    if (idx >= args.T_out * args.OC) {
        return;
    }

    const int t_out = idx % args.T_out;
    const int oc    = idx / args.T_out;
    const int t_abs = t_out + args.p0;  // absolute position in uncropped signal

    int t_in_min = (t_abs - args.K + args.s0) / args.s0;  // ceil((t_abs - K + 1) / s0)
    if (t_in_min < 0) {
        t_in_min = 0;
    }
    int t_in_max = t_abs / args.s0;
    if (t_in_max >= args.T_in) {
        t_in_max = args.T_in - 1;
    }

    float sum = 0.0f;
    for (int t_in = t_in_min; t_in <= t_in_max; t_in++) {
        const int k = t_abs - t_in * args.s0;
        sum += float(col[(oc * args.K + k) + t_in * args.K_OC]);
    }

    dst[t_out + oc * args.T_out] = T(sum);
}

template [[host_name("kernel_col2im_1d_f32")]]  kernel void kernel_col2im_1d<float>(constant ggml_metal_kargs_col2im_1d &, device const float *, device float *, uint, uint, uint);
template [[host_name("kernel_col2im_1d_f16")]]  kernel void kernel_col2im_1d<half>(constant ggml_metal_kargs_col2im_1d &, device const half *, device half *, uint, uint, uint);
#if defined(GGML_METAL_HAS_BF16)
template [[host_name("kernel_col2im_1d_bf16")]] kernel void kernel_col2im_1d<bfloat>(constant ggml_metal_kargs_col2im_1d &, device const bfloat *, device bfloat *, uint, uint, uint);
#endif

template <typename TK>
kernel void kernel_conv_2d(
        constant ggml_metal_kargs_conv_2d & args,
        device const char * weights,
        device const char * src,
        device       char * dst,
        uint3   tgpig[[threadgroup_position_in_grid]],
        uint3    tgpg[[threadgroups_per_grid]],
        uint3   tpitg[[thread_position_in_threadgroup]],
        uint3     ntg[[threads_per_threadgroup]]) {

    const uint threads_per_tg = ntg.x * ntg.y * ntg.z;
    const uint tg_index = (tgpig.z * tgpg.y + tgpig.y) * tgpg.x + tgpig.x;
    const uint local_thread = tpitg.z * (ntg.x * ntg.y) + tpitg.y * ntg.x + tpitg.x;
    const uint thread_index = tg_index * threads_per_tg + local_thread;
    const uint64_t total_threads = (uint64_t) threads_per_tg * tgpg.x * tgpg.y * tgpg.z;
    const uint64_t total_outputs = (uint64_t) args.N * args.OC * args.OH * args.OW;

    for (uint64_t index = thread_index; index < total_outputs; index += total_threads) {
        uint64_t tmp = index;

        const int32_t ow = tmp % args.OW; tmp /= args.OW;
        const int32_t oh = tmp % args.OH; tmp /= args.OH;
        const int32_t oc = tmp % args.OC; tmp /= args.OC;
        const int32_t  n = tmp;

        float acc = 0.0f;

        const int32_t base_x = ow*args.s0 - args.p0;
        const int32_t base_y = oh*args.s1 - args.p1;

        int32_t ky_start = 0;
        if (base_y < 0) {
            ky_start = (-base_y + args.d1 - 1)/args.d1;
        }
        int32_t ky_end = args.KH;
        const int32_t y_max = args.IH - 1 - base_y;
        if (y_max < 0) {
            ky_end = ky_start;
        } else if (base_y + (args.KH - 1)*args.d1 >= args.IH) {
            ky_end = min(ky_end, y_max/args.d1 + 1);
        }

        int32_t kx_start = 0;
        if (base_x < 0) {
            kx_start = (-base_x + args.d0 - 1)/args.d0;
        }
        int32_t kx_end = args.KW;
        const int32_t x_max = args.IW - 1 - base_x;
        if (x_max < 0) {
            kx_end = kx_start;
        } else if (base_x + (args.KW - 1)*args.d0 >= args.IW) {
            kx_end = min(kx_end, x_max/args.d0 + 1);
        }

        if (ky_start < ky_end && kx_start < kx_end) {
            const uint64_t src_base_n = (uint64_t) n  * args.nb13;
            const uint64_t w_base_oc  = (uint64_t) oc * args.nb03;

            for (int32_t ic = 0; ic < args.IC; ++ic) {
                const uint64_t src_base_nc = src_base_n + (uint64_t) ic * args.nb12;
                const uint64_t w_base_ocic = w_base_oc  + (uint64_t) ic * args.nb02;

                for (int32_t ky = ky_start; ky < ky_end; ++ky) {
                    const int32_t iy = base_y + ky*args.d1;
                    const uint64_t src_base_row = src_base_nc + (uint64_t) iy * args.nb11;
                    const uint64_t w_base_row   = w_base_ocic + (uint64_t) ky * args.nb01;

                    for (int32_t kx = kx_start; kx < kx_end; ++kx) {
                        const int32_t ix = base_x + kx*args.d0;
                        const uint64_t src_offs = src_base_row + (uint64_t) ix * args.nb10;
                        const uint64_t w_offs   = w_base_row   + (uint64_t) kx * args.nb00;

                        const float x = *(device const float *)(src + src_offs);
                        const float w = (float) (*(device const TK *)(weights + w_offs));

                        acc += x * w;
                    }
                }
            }
        }

        const uint64_t dst_offs =
            (uint64_t) n  * args.nb3 +
            (uint64_t) oc * args.nb2 +
            (uint64_t) oh * args.nb1 +
            (uint64_t) ow * args.nb0;

        *(device float *)(dst + dst_offs) = acc;
    }
}

template [[host_name("kernel_conv_2d_f32_f32")]]
kernel void kernel_conv_2d<float>(
        constant ggml_metal_kargs_conv_2d & args,
        device const char * weights,
        device const char * src,
        device       char * dst,
        uint3   tgpig[[threadgroup_position_in_grid]],
        uint3    tgpg[[threadgroups_per_grid]],
        uint3   tpitg[[thread_position_in_threadgroup]],
        uint3     ntg[[threads_per_threadgroup]]);

template [[host_name("kernel_conv_2d_f16_f32")]]
kernel void kernel_conv_2d<half>(
        constant ggml_metal_kargs_conv_2d & args,
        device const char * weights,
        device const char * src,
        device       char * dst,
        uint3   tgpig[[threadgroup_position_in_grid]],
        uint3    tgpg[[threadgroups_per_grid]],
        uint3   tpitg[[thread_position_in_threadgroup]],
        uint3     ntg[[threads_per_threadgroup]]);

typedef void (conv_transpose_1d_t)(
        constant ggml_metal_kargs_conv_transpose_1d & args,
        device const float * src0,
        device const float * src1,
        device        char * dst,
        uint3   tgpig[[threadgroup_position_in_grid]],
        uint3    tgpg[[threadgroups_per_grid]]);

template <typename T>
kernel void kernel_conv_transpose_1d(
        constant ggml_metal_kargs_conv_transpose_1d & args,
        device const     T * src0,
        device const float * src1,
        device        char * dst,
        uint3   tgpig[[threadgroup_position_in_grid]],
        uint3   tgpg[[threadgroups_per_grid]]) {

    // For output position j on the time axis, only input positions
    //   i such that i*s0 <= j < i*s0 + K
    // contribute -- i.e. i in [ceil((j - K + 1)/s0), floor(j/s0)]
    // intersected with [0, IL-1]. That's at most ceil(K/s0) values
    // (typically 2 for stride==K/2 transposed convs).
    const int32_t j  = tgpig[0];
    const int32_t s0 = args.s0;
    const int32_t K  = args.K;
    const int32_t IL = args.IL;

    int32_t i_min;
    {
        int32_t a = j - K + 1;
        i_min = a <= 0 ? 0 : (a + s0 - 1) / s0; // ceil(a/s0) for a>0
    }
    int32_t i_max = j / s0;
    if (i_max > IL - 1) i_max = IL - 1;

    float v = 0.0f;
    if (i_min <= i_max) {
        for (int64_t c = 0; c < args.IC; c++) {
            const int32_t kernel_offset = c * tgpg[1] * K + K * tgpig[1];
            const int32_t input_offset  = c * IL;

            for (int32_t i = i_min; i <= i_max; i++) {
                v += float(src0[kernel_offset + j - i * s0]) * src1[input_offset + i];
            }
        }
    }

    device float * dst_ptr = (device float *) (dst + tgpig[0] * args.nb0 + tgpig[1] * args.nb1);

    dst_ptr[0] = v;
}

template [[host_name("kernel_conv_transpose_1d_f32_f32")]]
kernel void kernel_conv_transpose_1d<float>(
    constant ggml_metal_kargs_conv_transpose_1d & args,
    device const float * src0,
    device const float * src1,
    device        char * dst,
    uint3   tgpig[[threadgroup_position_in_grid]],
    uint3    tgpg[[threadgroups_per_grid]]);

template [[host_name("kernel_conv_transpose_1d_f16_f32")]]
kernel void kernel_conv_transpose_1d<half>(
    constant ggml_metal_kargs_conv_transpose_1d & args,
    device const half  * src0,
    device const float * src1,
    device        char * dst,
    uint3   tgpig[[threadgroup_position_in_grid]],
    uint3    tgpg[[threadgroups_per_grid]]);


typedef void (conv_transpose_2d_t)(
        constant ggml_metal_kargs_conv_transpose_2d & args,
        device const float * src0,
        device const float * src1,
        device        char * dst,
        uint3   tgpig[[threadgroup_position_in_grid]],
        uint3    tgpg[[threadgroups_per_grid]]);

template <typename T>
kernel void kernel_conv_transpose_2d(
        constant ggml_metal_kargs_conv_transpose_2d & args,
        device const T * src0,
        device const float * src1,
        device        char * dst,
        threadgroup float * shared_sum [[threadgroup(0)]],
        uint3   tgpig[[threadgroup_position_in_grid]],
        uint3   tpitg[[thread_position_in_threadgroup]],
        uint3     ntg[[threads_per_threadgroup]]) {

    const int64_t out_x = tgpig[0];
    const int64_t out_y = tgpig[1];
    const int64_t batch = tgpig[2] / args.OC;
    const int64_t out_c = tgpig[2] % args.OC;

    const int64_t kw = tpitg[0];
    const int64_t kh = tpitg[1];

    float v = 0.0f;

    for (int64_t in_c = 0; in_c < args.IC; in_c++) {
        int64_t in_y = out_y - kh;

        if (in_y < 0 || in_y % args.s0) continue;

        in_y /= args.s0;

        if (in_y >= args.IH) continue;

        int64_t in_x = out_x - kw;

        if (in_x < 0 || in_x % args.s0) continue;

        in_x /= args.s0;

        if (in_x >= args.IW) continue;

        const int64_t input_idx = (args.IW * args.IH) * (args.IC * batch + in_c) + (args.IW) * in_y + in_x;
        const int64_t kernel_idx = (args.KH * args.KW * args.OC) * in_c + (args.KH * args.KW) * out_c + (args.KW) * kh + kw;

        v += (float)src0[kernel_idx] * src1[input_idx];
    }

    const uint tid = tpitg.y * ntg.x + tpitg.x;
    shared_sum[tid] = v;

    threadgroup_barrier(mem_flags::mem_threadgroup);

    if (tid == 0) {
        float total = 0.0f;
        const uint num_threads = ntg.x * ntg.y;
        for (uint i = 0; i < num_threads; i++) {
            total += shared_sum[i];
        }

        device float * dst_ptr = (device float *) (dst + batch*args.nb3 + out_c*args.nb2 + out_y * args.nb1 + out_x*args.nb0);
        dst_ptr[0] = total;
    }
}

template [[host_name("kernel_conv_transpose_2d_f32_f32")]]
kernel void kernel_conv_transpose_2d<float>(
    constant ggml_metal_kargs_conv_transpose_2d & args,
    device const float * src0,
    device const float * src1,
    device        char * dst,
    threadgroup float * shared_sum [[threadgroup(0)]],
    uint3   tgpig[[threadgroup_position_in_grid]],
    uint3   tpitg[[thread_position_in_threadgroup]],
    uint3     ntg[[threads_per_threadgroup]]);

template [[host_name("kernel_conv_transpose_2d_f16_f32")]]
kernel void kernel_conv_transpose_2d<half>(
    constant ggml_metal_kargs_conv_transpose_2d & args,
    device const half  * src0,
    device const float * src1,
    device        char * dst,
    threadgroup float * shared_sum [[threadgroup(0)]],
    uint3   tgpig[[threadgroup_position_in_grid]],
    uint3   tpitg[[thread_position_in_threadgroup]],
    uint3     ntg[[threads_per_threadgroup]]);

// grid: x = C tile, y = OH, z = OW * N (for channel-contiguous layouts)
template <typename TK>
kernel void kernel_conv_2d_dw_tiled(
        constant ggml_metal_kargs_conv_2d_dw & args,
        device const char * weights,
        device const char * src,
        device       char * dst,
        uint3   tgpig[[threadgroup_position_in_grid]],
        uint3   tpitg[[thread_position_in_threadgroup]],
        uint3     ntg[[threads_per_threadgroup]]) {

    const int32_t c = (int32_t)(tgpig.x * ntg.x + tpitg.x);
    if (c >= args.C) {
        return;
    }

    const int32_t oh = tgpig.y;
    const int32_t own = tgpig.z;
    const int32_t ow = own % args.OW;
    const int32_t n  = own / args.OW;

    const int32_t base_y = oh*args.s1 - args.p1;

    int32_t ky_start = 0;
    if (base_y < 0) {
        ky_start = (-base_y + args.d1 - 1)/args.d1;
    }
    int32_t ky_end = args.KH;
    const int32_t y_max = args.IH - 1 - base_y;
    if (y_max < 0) {
        ky_end = ky_start;
    } else if (base_y + (args.KH - 1)*args.d1 >= args.IH) {
        ky_end = min(ky_end, y_max/args.d1 + 1);
    }

    const int32_t base_x = ow*args.s0 - args.p0;

    int32_t kx_start = 0;
    if (base_x < 0) {
        kx_start = (-base_x + args.d0 - 1)/args.d0;
    }
    int32_t kx_end = args.KW;
    const int32_t x_max = args.IW - 1 - base_x;
    if (x_max < 0) {
        kx_end = kx_start;
    } else if (base_x + (args.KW - 1)*args.d0 >= args.IW) {
        kx_end = min(kx_end, x_max/args.d0 + 1);
    }

    float acc = 0.0f;

    if (ky_start < ky_end && kx_start < kx_end) {
        const uint64_t w_base   = (uint64_t) c * args.nb02;
        const uint64_t src_base = (uint64_t) n * args.nb13 + (uint64_t) c * args.nb12;

        for (int32_t ky = ky_start; ky < ky_end; ++ky) {
            const int32_t iy = base_y + ky*args.d1;
            const uint64_t src_row = src_base + (uint64_t) iy * args.nb11;
            const uint64_t w_row = w_base + (uint64_t) ky * args.nb01;

            for (int32_t kx = kx_start; kx < kx_end; ++kx) {
                const int32_t ix = base_x + kx*args.d0;
                const float x = *(device const float *)(src + src_row + (uint64_t) ix * args.nb10);
                const float w = (float)(*(device const TK *)(weights + w_row + (uint64_t) kx * args.nb00));
                acc += x * w;
            }
        }
    }

    const uint64_t dst_offs =
        (uint64_t) n  * args.nb3 +
        (uint64_t) c  * args.nb2 +
        (uint64_t) oh * args.nb1 +
        (uint64_t) ow * args.nb0;

    *(device float *)(dst + dst_offs) = acc;
}

// grid: x = OW tile, y = OH, z = C * N (for spatially-contiguous layouts)
template <typename TK>
kernel void kernel_conv_2d_dw(
        constant ggml_metal_kargs_conv_2d_dw & args,
        device const char * weights,
        device const char * src,
        device       char * dst,
        uint3   tgpig[[threadgroup_position_in_grid]],
        uint3   tpitg[[thread_position_in_threadgroup]],
        uint3     ntg[[threads_per_threadgroup]]) {

    const int32_t oh = tgpig.y;
    const int32_t cn = tgpig.z;
    const int32_t c  = cn % args.C;
    const int32_t n  = cn / args.C;

    const int32_t base_y = oh*args.s1 - args.p1;

    int32_t ky_start = 0;
    if (base_y < 0) {
        ky_start = (-base_y + args.d1 - 1)/args.d1;
    }
    int32_t ky_end = args.KH;
    const int32_t y_max = args.IH - 1 - base_y;
    if (y_max < 0) {
        ky_end = ky_start;
    } else if (base_y + (args.KH - 1)*args.d1 >= args.IH) {
        ky_end = min(ky_end, y_max/args.d1 + 1);
    }

    const uint64_t w_base   = (uint64_t) c * args.nb02;
    const uint64_t src_base = (uint64_t) n * args.nb13 + (uint64_t) c * args.nb12;

    const int32_t ow = (int32_t)(tgpig.x * ntg.x + tpitg.x);
    if (ow >= args.OW) {
        return;
    }

    float acc = 0.0f;

    const int32_t base_x = ow*args.s0 - args.p0;

    int32_t kx_start = 0;
    if (base_x < 0) {
        kx_start = (-base_x + args.d0 - 1)/args.d0;
    }
    int32_t kx_end = args.KW;
    const int32_t x_max = args.IW - 1 - base_x;
    if (x_max < 0) {
        kx_end = kx_start;
    } else if (base_x + (args.KW - 1)*args.d0 >= args.IW) {
        kx_end = min(kx_end, x_max/args.d0 + 1);
    }

    if (ky_start < ky_end && kx_start < kx_end) {
        for (int32_t ky = ky_start; ky < ky_end; ++ky) {
            const int32_t iy = base_y + ky*args.d1;
            const uint64_t src_row = src_base + (uint64_t) iy * args.nb11;
            const uint64_t w_row = w_base + (uint64_t) ky * args.nb01;

            for (int32_t kx = kx_start; kx < kx_end; ++kx) {
                const int32_t ix = base_x + kx*args.d0;
                const float x = *(device const float *)(src + src_row + (uint64_t) ix * args.nb10);
                const float w = (float)(*(device const TK *)(weights + w_row + (uint64_t) kx * args.nb00));
                acc += x * w;
            }
        }
    }

    const uint64_t dst_offs =
        (uint64_t) n  * args.nb3 +
        (uint64_t) c  * args.nb2 +
        (uint64_t) oh * args.nb1 +
        (uint64_t) ow * args.nb0;

    *(device float *)(dst + dst_offs) = acc;
}

template [[host_name("kernel_conv_2d_dw_f32_f32")]]
kernel void kernel_conv_2d_dw<float>(
        constant ggml_metal_kargs_conv_2d_dw & args,
        device const char * weights,
        device const char * src,
        device       char * dst,
        uint3   tgpig[[threadgroup_position_in_grid]],
        uint3   tpitg[[thread_position_in_threadgroup]],
        uint3     ntg[[threads_per_threadgroup]]);

template [[host_name("kernel_conv_2d_dw_f16_f32")]]
kernel void kernel_conv_2d_dw<half>(
        constant ggml_metal_kargs_conv_2d_dw & args,
        device const char * weights,
        device const char * src,
        device       char * dst,
        uint3   tgpig[[threadgroup_position_in_grid]],
        uint3   tpitg[[thread_position_in_threadgroup]],
        uint3     ntg[[threads_per_threadgroup]]);

template [[host_name("kernel_conv_2d_dw_tiled_f32_f32")]]
kernel void kernel_conv_2d_dw_tiled<float>(
        constant ggml_metal_kargs_conv_2d_dw & args,
        device const char * weights,
        device const char * src,
        device       char * dst,
        uint3   tgpig[[threadgroup_position_in_grid]],
        uint3   tpitg[[thread_position_in_threadgroup]],
        uint3     ntg[[threads_per_threadgroup]]);

template [[host_name("kernel_conv_2d_dw_tiled_f16_f32")]]
kernel void kernel_conv_2d_dw_tiled<half>(
        constant ggml_metal_kargs_conv_2d_dw & args,
        device const char * weights,
        device const char * src,
        device       char * dst,
        uint3   tgpig[[threadgroup_position_in_grid]],
        uint3   tpitg[[thread_position_in_threadgroup]],
        uint3     ntg[[threads_per_threadgroup]]);

template <typename T>
kernel void kernel_conv_3d(
        constant ggml_metal_kargs_conv_3d & args,
        device const  char * src0, // Weights [IC * OC, KD, KH, KW]
        device const  char * src1, // Inputs  [IC * N,  ID, IH, IW]
        device       char  * dst,  // Outputs [OC * N,  OD, OH, OW]
        uint3 tgpig[[threadgroup_position_in_grid]],
        uint3 tpitg[[thread_position_in_threadgroup]]) {

    // 1. Un-flatten the spatial dimension from Grid X
    int64_t spatial_idx = tgpig.x * 32 + tpitg.x;

    if (spatial_idx >= args.OW * args.OH * args.OD) {
        return; // Thread falls outside the spatial volume
    }

    int64_t od = spatial_idx / (args.OW * args.OH);
    int64_t oh = (spatial_idx / args.OW) % args.OH;
    int64_t ow = spatial_idx % args.OW;

    // 2. Map Y to Channels, Z to Batch
    int64_t oc = tgpig.y;
    int64_t batch_idx = tgpig.z;

    // 3. Calculate anchor coordinates in the Input volume
    int64_t i_w_base = ow * args.s0 - args.p0;
    int64_t i_h_base = oh * args.s1 - args.p1;
    int64_t i_d_base = od * args.s2 - args.p2;

    float sum = 0.0f;

    // 4. Gather Loop (Iterate over Input Channels -> Depth -> Height -> Width)
    for (int64_t ic = 0; ic < args.IC; ++ic) {

        // ggml packs batch and channel together in the 4th dimension
        int64_t src_cn_idx = batch_idx * args.IC + ic;
        int64_t w_cn_idx   = oc * args.IC + ic;

        for (int64_t kz = 0; kz < args.KD; ++kz) {
            int64_t id = i_d_base + kz * args.d2;
            if (id < 0 || id >= args.ID) continue; // Boundary check (Padding)

            for (int64_t ky = 0; ky < args.KH; ++ky) {
                int64_t ih = i_h_base + ky * args.d1;
                if (ih < 0 || ih >= args.IH) continue;

                for (int64_t kx = 0; kx < args.KW; ++kx) {
                    int64_t iw = i_w_base + kx * args.d0;
                    if (iw < 0 || iw >= args.IW) continue;

                    // Convert multi-dimensional coordinates to flat byte offsets
                    int64_t w_idx = kx*args.nb00 + ky*args.nb01 + kz*args.nb02 + w_cn_idx*args.nb03;
                    int64_t i_idx = iw*args.nb10 + ih*args.nb11 + id*args.nb12 + src_cn_idx*args.nb13;

                    // Dereference memory and cast weights to f32 if they were f16
                    float w_val = (float)*(device const T*)((device const char*)src0 + w_idx);
                    float i_val = *(device const float*)((device const char*)src1 + i_idx);

                    sum += w_val * i_val;
                }
            }
        }
    }

    // 5. Write the accumulated value out to RAM
    int64_t dst_cn_idx = batch_idx * args.OC + oc;
    int64_t d_idx = ow*args.nb0 + oh*args.nb1 + od*args.nb2 + dst_cn_idx*args.nb3;

    *(device float*)(dst + d_idx) = sum;
}

// Explicit instantiations so the JIT compiler can find them by name
template [[host_name("kernel_conv_3d_f32_f32")]]
kernel void kernel_conv_3d<float>(
    constant ggml_metal_kargs_conv_3d & args,
    device const char * src0,
    device const char * src1,
    device       char  * dst,
    uint3 tgpig[[threadgroup_position_in_grid]],
    uint3 tpitg[[thread_position_in_threadgroup]]);

// Explicit instantiation for f16 weights
template [[host_name("kernel_conv_3d_f16_f32")]]
kernel void kernel_conv_3d<half>(
    constant ggml_metal_kargs_conv_3d & args,
    device const char  * src0,
    device const char * src1,
    device       char  * dst,
    uint3 tgpig[[threadgroup_position_in_grid]],
    uint3 tpitg[[thread_position_in_threadgroup]]);
