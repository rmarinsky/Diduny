
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

constant bool FC_ssm_conv_silu [[function_constant(FC_SSM_CONV + 1)]];
constant int  FC_ssm_conv_nc    [[function_constant(FC_SSM_CONV + 2)]];

// ref: ggml.c:ggml_compute_forward_ssm_conv_f32
kernel void kernel_ssm_conv_f32_f32(
        constant ggml_metal_kargs_ssm_conv & args,
        device const  void * src0,
        device const  void * src1,
        device       float * dst,
        uint3 tgpig[[threadgroup_position_in_grid]],
        uint3 tpitg[[thread_position_in_threadgroup]],
        uint3   ntg[[threads_per_threadgroup]]) {
    const int64_t ir = tgpig.x;
    const int64_t i2 = tgpig.y;
    const int64_t i3 = tgpig.z;

    const int64_t nc  = FC_ssm_conv_nc;
  //const int64_t ncs = args.ne00;
  //const int64_t nr  = args.ne01;
  //const int64_t n_t = args.ne1;
  //const int64_t n_s = args.ne2;

    device const float * s = (device const float *) ((device const char *) src0 + ir*args.nb01 + i2*args.nb00 + i3*args.nb02);
    device const float * c = (device const float *) ((device const char *) src1 + ir*args.nb11);
    device       float * x = (device       float *) ((device       char *) dst  + ir*args.nb0  + i2*args.nb1  + i3*args.nb2);

    float sumf = 0.0f;

    FOR_UNROLL (int64_t i0 = 0; i0 < nc; ++i0) {
        sumf += s[i0] * c[i0];
    }

    x[0] = FC_ssm_conv_silu ? sumf/(1.0f + exp(-sumf)) : sumf;
}

kernel void kernel_ssm_conv_f32_f32_4(
        constant ggml_metal_kargs_ssm_conv & args,
        device const  void * src0,
        device const  void * src1,
        device       float * dst,
        uint3 tgpig[[threadgroup_position_in_grid]],
        uint3 tpitg[[thread_position_in_threadgroup]],
        uint3   ntg[[threads_per_threadgroup]]) {
    const int64_t ir = tgpig.x;
    const int64_t i2 = tgpig.y;
    const int64_t i3 = tgpig.z;

    const int64_t nc  = FC_ssm_conv_nc;
  //const int64_t ncs = args.ne00;
  //const int64_t nr  = args.ne01;
  //const int64_t n_t = args.ne1;
  //const int64_t n_s = args.ne2;

    device const float4 * s = (device const float4 *) ((device const char *) src0 + ir*args.nb01 + i2*args.nb00 + i3*args.nb02);
    device const float4 * c = (device const float4 *) ((device const char *) src1 + ir*args.nb11);
    device       float  * x = (device       float  *) ((device       char *) dst  + ir*args.nb0  + i2*args.nb1  + i3*args.nb2);

    float sumf = 0.0f;

    FOR_UNROLL (int64_t i0 = 0; i0 < nc/4; ++i0) {
        sumf += dot(s[i0], c[i0]);
    }

    x[0] = FC_ssm_conv_silu ? sumf/(1.0f + exp(-sumf)) : sumf;
}

constant short FC_ssm_conv_bs   [[function_constant(FC_SSM_CONV + 0)]];

// Batched version: each threadgroup processes multiple tokens for better efficiency
// Thread layout: each thread handles one token, threadgroup covers BATCH_SIZE tokens
kernel void kernel_ssm_conv_f32_f32_batched(
        constant ggml_metal_kargs_ssm_conv & args,
        device const  void * src0,
        device const  void * src1,
        device       float * dst,
        uint3 tgpig[[threadgroup_position_in_grid]],
        uint3 tpitg[[thread_position_in_threadgroup]],
        uint3   ntg[[threads_per_threadgroup]]) {
    // tgpig.x = row index (ir)
    // tgpig.y = batch of tokens (i2_base / BATCH_SIZE)
    // tgpig.z = sequence index (i3)
    // tpitg.x = thread within batch (0..BATCH_SIZE-1)
    const short BATCH_SIZE = FC_ssm_conv_bs;

    const int64_t ir      = tgpig.x;
    const int64_t i2_base = tgpig.y * BATCH_SIZE;
    const int64_t i3      = tgpig.z;
    const int64_t i2_off  = tpitg.x;
    const int64_t i2      = i2_base + i2_off;

    const int64_t nc  = FC_ssm_conv_nc;  // conv kernel size (typically 4)
    const int64_t n_t = args.ne1;   // number of tokens

    // Bounds check for partial batches at the end
    if (i2 >= n_t) {
        return;
    }

    // Load conv weights (shared across all tokens for this row)
    device const float * c = (device const float *) ((device const char *) src1 + ir*args.nb11);

    // Load source for this specific token
    device const float * s = (device const float *) ((device const char *) src0 + ir*args.nb01 + i2*args.nb00 + i3*args.nb02);

    // Output location for this token
    device float * x = (device float *) ((device char *) dst + ir*args.nb0 + i2*args.nb1 + i3*args.nb2);

    float sumf = 0.0f;
    FOR_UNROLL (int64_t i0 = 0; i0 < nc; ++i0) {
        sumf += s[i0] * c[i0];
    }

    x[0] = FC_ssm_conv_silu ? sumf/(1.0f + exp(-sumf)) : sumf;
}

kernel void kernel_ssm_conv_f32_f32_batched_4(
        constant ggml_metal_kargs_ssm_conv & args,
        device const  void * src0,
        device const  void * src1,
        device       float * dst,
        uint3 tgpig[[threadgroup_position_in_grid]],
        uint3 tpitg[[thread_position_in_threadgroup]],
        uint3   ntg[[threads_per_threadgroup]]) {
    // tgpig.x = row index (ir)
    // tgpig.y = batch of tokens (i2_base / BATCH_SIZE)
    // tgpig.z = sequence index (i3)
    // tpitg.x = thread within batch (0..BATCH_SIZE-1)
    const short BATCH_SIZE = FC_ssm_conv_bs;

    const int64_t ir      = tgpig.x;
    const int64_t i2_base = tgpig.y * BATCH_SIZE;
    const int64_t i3      = tgpig.z;
    const int64_t i2_off  = tpitg.x;
    const int64_t i2      = i2_base + i2_off;

    const int64_t nc  = FC_ssm_conv_nc;  // conv kernel size (typically 4)
    const int64_t n_t = args.ne1;   // number of tokens

    // Bounds check for partial batches at the end
    if (i2 >= n_t) {
        return;
    }

    // Load conv weights (shared across all tokens for this row)
    device const float4 * c = (device const float4 *) ((device const char *) src1 + ir*args.nb11);

    // Load source for this specific token
    device const float4 * s = (device const float4 *) ((device const char *) src0 + ir*args.nb01 + i2*args.nb00 + i3*args.nb02);

    // Output location for this token
    device float * x = (device float *) ((device char *) dst + ir*args.nb0 + i2*args.nb1 + i3*args.nb2);

    float sumf = 0.0f;
    FOR_UNROLL (int64_t i0 = 0; i0 < nc/4; ++i0) {
        sumf += dot(s[i0], c[i0]);
    }

    x[0] = FC_ssm_conv_silu ? sumf/(1.0f + exp(-sumf)) : sumf;
}

// ref: ggml.c:ggml_compute_forward_ssm_scan_f32, Mamba-2 part
// Optimized version: reduces redundant memory loads by having one thread load shared values
// TAIL == false is the whole-sequence / decode path: token_offset folds away at compile time.
template<bool TAIL>
kernel void kernel_ssm_scan_impl(
        constant ggml_metal_kargs_ssm_scan & args,
        device const void * src0,
        device const void * src1,
        device const void * src2,
        device const void * src3,
        device const void * src4,
        device const void * src5,
        device const void * src6,
        device      float * dst,
        threadgroup float * shared [[threadgroup(0)]],
        uint3   tgpig[[threadgroup_position_in_grid]],
        ushort3 tpitg[[thread_position_in_threadgroup]],
        ushort  sgitg[[simdgroup_index_in_threadgroup]],
        ushort  tiisg[[thread_index_in_simdgroup]],
        ushort  sgptg[[simdgroups_per_threadgroup]],
        uint3    tgpg[[threadgroups_per_grid]]) {
    constexpr short NW = N_SIMDWIDTH;

    // Shared memory layout:
    // [0..sgptg*NW-1]: partial sums for reduction (existing)
    // [sgptg*NW..sgptg*NW+sgptg-1]: pre-computed x_dt values for each token in batch
    // [sgptg*NW+sgptg..sgptg*NW+2*sgptg-1]: pre-computed dA values for each token in batch
    threadgroup float * shared_sums = shared;
    threadgroup float * shared_x_dt = shared + sgptg * NW;
    threadgroup float * shared_dA   = shared + sgptg * NW + sgptg;

    shared_sums[tpitg.x] = 0.0f;

    const int32_t i0 = tpitg.x;
    const int32_t i1 = tgpig.x;
    const int32_t ir = tgpig.y; // current head
    const int32_t i3 = tgpig.z; // current seq

    const int32_t nc  = args.d_state;
    const int32_t nr  = args.d_inner;
    const int32_t nh  = args.n_head;
    const int32_t ng  = args.n_group;
    const int32_t n_t = args.n_seq_tokens;
    const int32_t n_s = args.n_seqs;
    const int32_t K   = args.K;
    const int32_t n_t_total = TAIL ? args.n_seq_tokens_total : n_t;
    const int32_t t_off     = TAIL ? args.token_offset       : 0;

    const int32_t s_off = args.s_off;

    device const int32_t * ids = (device const int32_t *) src6;

    device       float * s_buff  = (device       float *) ((device       char *) dst  + ir*args.nb02 +      i3*args.nb03 + s_off);
    device const float * s0_buff = t_off != 0 ?
        s_buff :
        (device const float *) ((device const char *) src0 + ir*args.nb02 + ids[i3]*args.nb03);

    const int32_t i = i0 + i1*nc;
    const int32_t g = ir / (nh / ng); // repeat_interleave

    float s0 = s0_buff[i];
    float s  = 0.0f;

    device const float * A = (device const float *) ((device const char *) src3 + ir*args.nb31); // {ne30, nh}

    const float A0 = A[i0%args.ne30];

    device const float * x  = (device const float *)((device const char *) src1 + i1*args.nb10 + ir*args.nb11 + t_off*args.nb12 + i3*args.nb13); // {dim, nh, nt, ns}
    device const float * dt = (device const float *)((device const char *) src2 + ir*args.nb20 + t_off*args.nb21 + i3*args.nb22);                 // {nh, nt, ns}
    device const float * B  = (device const float *)((device const char *) src4 + g*args.nb41 + t_off*args.nb42 + i3*args.nb43);                  // {d_state, ng, nt, ns}
    device const float * C  = (device const float *)((device const char *) src5 + g*args.nb51 + t_off*args.nb52 + i3*args.nb53);                  // {d_state, ng, nt, ns}

    device float * y = dst + (i1 + ir*nr + t_off*nh*nr + i3*(n_t_total*nh*nr)); // {dim, nh, nt, ns}

    for (int i2 = 0; i2 < n_t; i2 += sgptg) {
        threadgroup_barrier(mem_flags::mem_threadgroup);

        // Pre-compute x_dt and dA for this batch of tokens
        // Only first sgptg threads do the loads and expensive math
        if (i0 < sgptg && i2 + i0 < n_t) {
            // ns12 and ns21 are element strides (nb12/nb10, nb21/nb20)
            device const float * x_t  = x  + i0 * args.ns12;
            device const float * dt_t = dt + i0 * args.ns21;

            const float dt0  = dt_t[0];
            const float dtsp = dt0 <= 20.0f ? log(1.0f + exp(dt0)) : dt0;
            shared_x_dt[i0] = x_t[0] * dtsp;
            shared_dA[i0]   = dtsp;  // Store dtsp, compute exp(dtsp * A0) per-thread since A0 varies
        }

        threadgroup_barrier(mem_flags::mem_threadgroup);

        for (int t = 0; t < sgptg && i2 + t < n_t; t++) {
            const float x_dt = shared_x_dt[t];
            const float dA   = exp(shared_dA[t] * A0);

            s = (s0 * dA) + (B[i0] * x_dt);

            const float sumf = simd_sum(s * C[i0]);

            if (tiisg == 0) {
                shared_sums[t*NW + sgitg] = sumf;
            }

            // recurse
            s0 = s;

            const int32_t slot = n_t - 1 - (i2 + t);
            if (slot > 0 && slot < K) {
                device float * s_snapshot = (device float *) ((device char *) s_buff + (int64_t) slot*n_s*args.nb03);
                s_snapshot[i] = s;
            }

            B  += args.ns42;
            C  += args.ns52;
        }

        // Advance pointers for next batch
        x  += sgptg * args.ns12;
        dt += sgptg * args.ns21;

        threadgroup_barrier(mem_flags::mem_threadgroup);

        const float sumf = simd_sum(shared_sums[sgitg*NW + tiisg]);

        if (tiisg == 0 && i2 + sgitg < n_t) {
            y[sgitg*nh*nr] = sumf;
        }

        y += sgptg*nh*nr;
    }

    s_buff[i] = s;
}

typedef decltype(kernel_ssm_scan_impl<false>) kernel_ssm_scan_t;

template [[host_name("kernel_ssm_scan_f32")]]      kernel kernel_ssm_scan_t kernel_ssm_scan_impl<false>;
template [[host_name("kernel_ssm_scan_f32_tail")]] kernel kernel_ssm_scan_t kernel_ssm_scan_impl<true>;

// Chunked SSD SSM scan via Metal simdgroup MMatrix Multiply-Accumulate (simdgroup_float8x8) fast path.
// One threadgroup per (head, sequence) and tokens are processed in chunks.
// C*B^T computed in each chunk one time and reused across the head_dim channel tiles.
kernel void kernel_ssm_scan_ssd_mma_f32(
        constant ggml_metal_kargs_ssm_scan & args,
        device const void * src0,
        device const void * src1,
        device const void * src2,
        device const void * src3,
        device const void * src4,
        device const void * src5,
        device const void * src6,
        device      float * dst,
        threadgroup float * shared [[threadgroup(0)]],
        uint3   tgpig[[threadgroup_position_in_grid]],
        ushort  tiitg[[thread_index_in_threadgroup]],
        ushort  sgitg[[simdgroup_index_in_threadgroup]],
        ushort  tiisg[[thread_index_in_simdgroup]]) {
    constexpr short CS  = OP_SSM_SCAN_SSD_CS;
    constexpr short TC  = 8; // Tile Count of each edge in a simdgroup 8x8 tile
    constexpr short HD  = OP_SSM_SCAN_SSD_HD;
    constexpr short NSG = OP_SSM_SCAN_SSD_NSG;

    // acs/exp(acs)/state-decay vectors, dtX[CS][HD], four private SAM row tiles [8][CS],
    // and two 8x8 scratch tiles per simdgroup. Total: 26.75 KiB.
    threadgroup float * shared_acs         = shared;
    threadgroup float * shared_exp_acs     = shared + CS;
    threadgroup float * shared_state_decay = shared + 2*CS;
    threadgroup float * shared_dtx         = shared + 3*CS;
    threadgroup float * shared_sam         = shared + 3*CS + CS*HD;
    threadgroup float * sam_rows    = shared_sam + sgitg*TC*CS;
    threadgroup float * shared_tile = shared_sam + NSG*TC*CS;
    threadgroup float * tile0       = shared_tile + sgitg*2*TC*TC;
    threadgroup float * tile1       = tile0 + TC*TC;

    const int32_t ir = tgpig.y; // current head
    const int32_t i3 = tgpig.z; // current seq

    const int32_t nc  = args.d_state;
    const int32_t nr  = args.d_inner;
    const int32_t nh  = args.n_head;
    const int32_t ng  = args.n_group;
    const int32_t n_t = args.n_seq_tokens;
    const int32_t n_t_total = args.n_seq_tokens_total;
    const int32_t g   = ir / (nh / ng);

    device const int32_t * ids = (device const int32_t *) src6;

    device const float * s0_buff = (device const float *) ((device const char *) src0 + ir*args.nb02 + ids[i3]*args.nb03);
    device       float * s_buff  = (device       float *) ((device       char *) dst  + ir*args.nb02 +      i3*args.nb03 + args.s_off);

    device const float * A  = (device const float *) ((device const char *) src3 + ir*args.nb31);
    device const float * x  = (device const float *) ((device const char *) src1 + ir*args.nb11 + i3*args.nb13);
    device const float * dt = (device const float *) ((device const char *) src2 + ir*args.nb20 + i3*args.nb22);
    device const float * B  = (device const float *) ((device const char *) src4 +  g*args.nb41 + i3*args.nb43);
    device const float * C  = (device const float *) ((device const char *) src5 +  g*args.nb51 + i3*args.nb53);

    device float * y = dst + (ir*nr + i3*(n_t_total*nh*nr));

    for (int32_t t0 = 0; t0 < n_t; t0 += CS) {
        for (int32_t idx = tiitg; idx < CS*HD; idx += NSG*N_SIMDWIDTH) {
            const int32_t t = idx / HD;
            const int32_t c = idx % HD;
            const float dt0  = dt[(t0 + t) * (int32_t) args.ns21];
            const float dtsp = dt0 <= 20.0f ? log(1.0f + exp(dt0)) : dt0;
            shared_dtx[idx] = x[(t0 + t) * (int32_t) args.ns12 + c] * dtsp;
        }
        if (tiitg < CS) {
            const float dt0  = dt[(t0 + tiitg) * (int32_t) args.ns21];
            const float dtsp = dt0 <= 20.0f ? log(1.0f + exp(dt0)) : dt0;
            shared_acs[tiitg] = dtsp * A[0];
        }
        threadgroup_barrier(mem_flags::mem_threadgroup);

        if (tiitg == 0) {
            float acc = 0.0f;
            for (short t = 0; t < CS; ++t) {
                acc += shared_acs[t];
                shared_acs[t] = acc;
            }
        }
        threadgroup_barrier(mem_flags::mem_threadgroup);
        if (tiitg < CS) {
            shared_exp_acs[tiitg] = exp(shared_acs[tiitg]);
            shared_state_decay[tiitg] = exp(shared_acs[CS - 1] - shared_acs[tiitg]);
        }
        threadgroup_barrier(mem_flags::mem_threadgroup);

        device const float * state = t0 == 0 ? s0_buff : s_buff;

        // Build one 8x64 row tile of SAM per simdgroup, then reuse it across every channel tile.
        for (short ib = sgitg; ib < CS/TC; ib += NSG) {
            for (short jb = 0; jb <= ib; ++jb) {
                simdgroup_float8x8 cb = make_filled_simdgroup_matrix<float, 8>(0.0f);

                for (int32_t k0 = 0; k0 < nc; k0 += TC) {
                    simdgroup_float8x8 mc;
                    simdgroup_float8x8 mb;
                    simdgroup_load(mc, C + (t0 + ib*TC)*(int32_t) args.ns52 + k0, args.ns52);
                    simdgroup_load(mb, B + (t0 + jb*TC)*(int32_t) args.ns42 + k0, args.ns42, 0, true);
                    simdgroup_multiply_accumulate(cb, mc, mb, cb);
                }

                threadgroup float * sam = sam_rows + jb*TC;
                simdgroup_store(cb, sam, CS);
                simdgroup_barrier(mem_flags::mem_threadgroup);
                for (short e = tiisg; e < TC*TC; e += N_SIMDWIDTH) {
                    const short ri = e / TC;
                    const short rj = e % TC;
                    const short i  = ib*TC + ri;
                    const short j  = jb*TC + rj;
                    sam[ri*CS + rj] = j <= i ?
                        sam[ri*CS + rj] * exp(shared_acs[i] - shared_acs[j]) : 0.0f;
                }
                simdgroup_barrier(mem_flags::mem_threadgroup);
            }

            for (short ch = 0; ch < HD/TC; ++ch) {
                simdgroup_float8x8 y_diag  = make_filled_simdgroup_matrix<float, 8>(0.0f);
                simdgroup_float8x8 y_inter = make_filled_simdgroup_matrix<float, 8>(0.0f);

                for (short jb = 0; jb <= ib; ++jb) {
                    simdgroup_float8x8 sam;
                    simdgroup_float8x8 mdtx;
                    simdgroup_load(sam,  sam_rows + jb*TC,                   CS);
                    simdgroup_load(mdtx, shared_dtx + jb*TC*HD + ch*TC,     HD);
                    simdgroup_multiply_accumulate(y_diag, sam, mdtx, y_diag);
                }

                for (int32_t k0 = 0; k0 < nc; k0 += TC) {
                    simdgroup_float8x8 mc;
                    simdgroup_float8x8 ms;
                    simdgroup_load(mc, C + (t0 + ib*TC)*(int32_t) args.ns52 + k0, args.ns52);
                    simdgroup_load(ms, state + ch*TC*nc + k0, nc, 0, true);
                    simdgroup_multiply_accumulate(y_inter, mc, ms, y_inter);
                }

                simdgroup_store(y_diag,  tile0, TC);
                simdgroup_store(y_inter, tile1, TC);
                simdgroup_barrier(mem_flags::mem_threadgroup);
                for (short e = tiisg; e < TC*TC; e += N_SIMDWIDTH) {
                    const short ri = e / TC;
                    const short ci = e % TC;
                    const int32_t token = t0 + ib*TC + ri;
                    y[token*nh*nr + ch*TC + ci] =
                        tile0[e] + shared_exp_acs[ib*TC + ri] * tile1[e];
                }
                simdgroup_barrier(mem_flags::mem_threadgroup);
            }
        }

        // All simdgroups must finish reading s_buff before any thread overwrites it.
        threadgroup_barrier(mem_flags::mem_device | mem_flags::mem_threadgroup);

        // Keep the carried-state reduction in token order. Reassociating this particular product
        // with MMA compounds rounding differences at every chunk boundary; CB, y_diag, and C*S
        // remain on the matrix unit.
        const float chunk_decay = exp(shared_acs[CS - 1]);
        for (int32_t idx = tiitg; idx < nc*HD; idx += NSG*N_SIMDWIDTH) {
            const int32_t ci = idx / nc;
            const int32_t si = idx % nc;
            float state_c = 0.0f;
            for (short t = 0; t < CS; ++t) {
                state_c += shared_state_decay[t] *
                    B[(t0 + t)*(int32_t) args.ns42 + si] *
                    shared_dtx[t*HD + ci];
            }
            s_buff[idx] = chunk_decay * state[idx] + state_c;
        }

        // All state tiles must be visible before the next chunk consumes s_buff as S_prev.
        threadgroup_barrier(mem_flags::mem_device | mem_flags::mem_threadgroup);
    }
}
