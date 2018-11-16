#pragma once
#include "constant_tensor_descriptor.cuh"
#include "blockwise_tensor_op.cuh"
#include "threadwise_tensor_op.cuh"
#include "threadwise_convolution.cuh"

template <class TFloat,
          class InDesc,
          class WeiDesc,
          class OutDesc,
          unsigned OutTileSizeH,
          unsigned OutTileSizeW,
          unsigned BlockSize>
__device__ void blockwise_convolution(InDesc,
                                      TFloat* const __restrict__ p_in_lds,
                                      WeiDesc,
                                      TFloat* const __restrict__ p_wei_lds,
                                      OutDesc,
                                      TFloat* __restrict__ p_out_lds)
{
    constexpr auto I0 = Index<0>{};
    constexpr auto I1 = Index<1>{};
    constexpr auto I2 = Index<2>{};
    constexpr auto I3 = Index<3>{};

    constexpr auto in_desc  = InDesc{};
    constexpr auto wei_desc = WeiDesc{};
    constexpr auto out_desc = OutDesc{};

    constexpr unsigned S = wei_desc.GetLength(I2);
    constexpr unsigned R = wei_desc.GetLength(I3);

    constexpr unsigned NPerBlock = out_desc.GetLength(I0);
    constexpr unsigned KPerBlock = out_desc.GetLength(I1);
    constexpr unsigned YPerBlock = (out_desc.GetLength(I2) + OutTileSizeH - 1) / OutTileSizeH;
    constexpr unsigned XPerBlock = (out_desc.GetLength(I3) + OutTileSizeW - 1) / OutTileSizeW;

    constexpr unsigned CPerBlock = in_desc.GetLength(I1);

    constexpr unsigned InTileSizeH = OutTileSizeH + S - 1;
    constexpr unsigned InTileSizeW = OutTileSizeW + R - 1;

#if 0
    if(threadIdx.x == 0)
    {
        print_ConstantTensorDescriptor(in_desc);
        print_ConstantTensorDescriptor(wei_desc);
        print_ConstantTensorDescriptor(out_desc);
    }
#endif

    constexpr auto in_thread_src_desc = make_ConstantTensorDescriptor(
        Sequence<1, CPerBlock, InTileSizeH, InTileSizeW>{}, in_desc.GetStrides());

    constexpr auto wei_thread_src_desc =
        make_ConstantTensorDescriptor(Sequence<1, CPerBlock, S, R>{}, wei_desc.GetStrides());

    constexpr auto out_thread_src_desc = make_ConstantTensorDescriptor(
        Sequence<1, 1, OutTileSizeH, OutTileSizeW>{}, out_desc.GetStrides());

    constexpr auto in_thread_dst_desc =
        make_ConstantTensorDescriptor(in_thread_src_desc.GetLengths());

    constexpr auto wei_thread_dst_desc =
        make_ConstantTensorDescriptor(wei_thread_src_desc.GetLengths());

    constexpr auto out_thread_dst_desc =
        make_ConstantTensorDescriptor(out_thread_src_desc.GetLengths());

    const unsigned thread_id = threadIdx.x;

    for(unsigned thread_work_id = thread_id; thread_work_id < NPerBlock * YPerBlock * XPerBlock;
        thread_work_id += BlockSize)
    {
        unsigned itmp             = thread_work_id;
        unsigned n_thread_work_id = itmp / (YPerBlock * XPerBlock);
        itmp -= n_thread_work_id * (YPerBlock * XPerBlock);
        unsigned y_thread_work_id = itmp / XPerBlock;
        unsigned x_thread_work_id = itmp - y_thread_work_id * XPerBlock;

        unsigned n_thread_work_begin  = n_thread_work_id * 1;
        unsigned ho_thread_work_begin = y_thread_work_id * OutTileSizeH;
        unsigned wo_thread_work_begin = x_thread_work_id * OutTileSizeW;

        unsigned hi_thread_work_begin = ho_thread_work_begin; // minus padding
        unsigned wi_thread_work_begin = wo_thread_work_begin; // minus padding

        TFloat p_in_thread[in_thread_src_desc.GetElementSpace()];
        TFloat p_wei_thread[wei_thread_src_desc.GetElementSpace()];
        TFloat p_out_thread[out_thread_src_desc.GetElementSpace()];

        auto f_copy = [](const TFloat& src, TFloat& dst) { dst = src; };

        // copy input tensor into register
        threadwise_4d_tensor_op_in<TFloat,
                                   decltype(in_thread_src_desc),
                                   decltype(in_thread_dst_desc),
                                   decltype(f_copy)>(
            in_thread_src_desc,
            p_in_lds + in_desc.Get1dIndex(
                           n_thread_work_begin, 0, hi_thread_work_begin, wi_thread_work_begin),
            in_thread_dst_desc,
            p_in_thread,
            f_copy);

        for(unsigned k_thread_work_begin = 0; k_thread_work_begin < KPerBlock;
            ++k_thread_work_begin)
        {
            // copy weight tensor into register
            threadwise_4d_tensor_op_wei<TFloat,
                                        decltype(wei_thread_src_desc),
                                        decltype(wei_thread_dst_desc),
                                        decltype(f_copy)>(
                wei_thread_src_desc,
                p_wei_lds + wei_desc.Get1dIndex(k_thread_work_begin, 0, 0, 0),
                wei_thread_dst_desc,
                p_wei_thread,
                f_copy);

            // copy output tensor into register
            threadwise_4d_tensor_op_out<TFloat,
                                        decltype(out_thread_src_desc),
                                        decltype(out_thread_dst_desc),
                                        decltype(f_copy)>(
                out_thread_src_desc,
                p_out_lds + out_desc.Get1dIndex(n_thread_work_begin,
                                                k_thread_work_begin,
                                                ho_thread_work_begin,
                                                wo_thread_work_begin),
                out_thread_dst_desc,
                p_out_thread,
                f_copy);

            // threadwise convolution
            threadwise_direct_convolution<TFloat,
                                          decltype(in_thread_dst_desc),
                                          decltype(wei_thread_dst_desc),
                                          decltype(out_thread_dst_desc)>(in_thread_dst_desc,
                                                                         p_in_thread,
                                                                         wei_thread_dst_desc,
                                                                         p_wei_thread,
                                                                         out_thread_dst_desc,
                                                                         p_out_thread);

            // accumulate output tensor into LDS
            threadwise_4d_tensor_op_out<TFloat,
                                        decltype(out_thread_dst_desc),
                                        decltype(out_thread_src_desc),
                                        decltype(f_copy)>(
                out_thread_dst_desc,
                p_out_thread,
                out_thread_src_desc,
                p_out_lds + out_desc.Get1dIndex(n_thread_work_begin,
                                                k_thread_work_begin,
                                                ho_thread_work_begin,
                                                wo_thread_work_begin),
                f_copy);
        }
    }
}

template <class TFloat,
          class InDesc,
          class WeiDesc,
          class OutDesc,
          unsigned OutTileSizeH,
          unsigned OutTileSizeW,
          unsigned NPerBlock,
          unsigned KPerBlock,
          unsigned CPerBlock,
          unsigned YPerBlock,
          unsigned XPerBlock,
          unsigned NBlockOpLen0,
          unsigned NBlockOpLen1,
          unsigned NBlockOpLen2,
          unsigned NBlockOpLen3,
          unsigned BlockSize,
          unsigned GridSize>
__global__ void gridwise_convolution(InDesc,
                                     TFloat* const __restrict__ p_in_glb,
                                     WeiDesc,
                                     TFloat* const __restrict__ p_wei_glb,
                                     OutDesc,
                                     TFloat* __restrict__ p_out_glb)
{
    constexpr auto I0 = Index<0>{};
    constexpr auto I1 = Index<1>{};
    constexpr auto I2 = Index<2>{};
    constexpr auto I3 = Index<3>{};

    constexpr auto in_desc  = InDesc{};
    constexpr auto wei_desc = WeiDesc{};
    constexpr auto out_desc = OutDesc{};

    constexpr unsigned S = wei_desc.GetLength(I2);
    constexpr unsigned R = wei_desc.GetLength(I3);

    constexpr unsigned HoPerBlock = OutTileSizeH * YPerBlock;
    constexpr unsigned WoPerBlock = OutTileSizeW * XPerBlock;

    constexpr unsigned HiPerBlock = YPerBlock * OutTileSizeH + S - 1;
    constexpr unsigned WiPerBlock = XPerBlock * OutTileSizeW + R - 1;

    constexpr unsigned NBlockWork = (out_desc.GetLength(I0) + NPerBlock - 1) / NPerBlock;
    constexpr unsigned KBlockWork = (out_desc.GetLength(I1) + KPerBlock - 1) / KPerBlock;
    constexpr unsigned YBlockWork = (out_desc.GetLength(I2) + HoPerBlock - 1) / HoPerBlock;
    constexpr unsigned XBlockWork = (out_desc.GetLength(I3) + WoPerBlock - 1) / WoPerBlock;

    constexpr auto in_block_glb_desc = make_ConstantTensorDescriptor(
        Sequence<NPerBlock, CPerBlock, HiPerBlock, WiPerBlock>{}, in_desc.GetStrides());

    constexpr auto wei_block_glb_desc = make_ConstantTensorDescriptor(
        Sequence<KPerBlock, CPerBlock, S, R>{}, wei_desc.GetStrides());

    constexpr auto out_block_glb_desc = make_ConstantTensorDescriptor(
        Sequence<NPerBlock, KPerBlock, HoPerBlock, WoPerBlock>{}, out_desc.GetStrides());

    constexpr auto in_block_lds_desc =
        make_ConstantTensorDescriptor(in_block_glb_desc.GetLengths());
    constexpr auto wei_block_lds_desc =
        make_ConstantTensorDescriptor(wei_block_glb_desc.GetLengths());
    constexpr auto out_block_lds_desc =
        make_ConstantTensorDescriptor(out_block_glb_desc.GetLengths());

    constexpr unsigned in_block_size  = in_block_lds_desc.GetElementSpace();
    constexpr unsigned wei_block_size = wei_block_lds_desc.GetElementSpace();
    constexpr unsigned out_block_size = out_block_lds_desc.GetElementSpace();

    __shared__ TFloat p_in_block_lds[in_block_size];
    __shared__ TFloat p_wei_block_lds[wei_block_size];
    __shared__ TFloat p_out_block_lds[out_block_size];

    const unsigned block_id = blockIdx.x;

    unsigned itmp            = block_id;
    unsigned n_block_work_id = itmp / (KBlockWork * YBlockWork * XBlockWork);
    itmp -= n_block_work_id * (KBlockWork * YBlockWork * XBlockWork);
    unsigned k_block_work_id = itmp / (YBlockWork * XBlockWork);
    itmp -= k_block_work_id * (YBlockWork * XBlockWork);
    unsigned y_block_work_id = itmp / XBlockWork;
    unsigned x_block_work_id = itmp - y_block_work_id * XBlockWork;

    unsigned n_block_work_begin = n_block_work_id * NPerBlock;
    unsigned k_block_work_begin = k_block_work_id * KPerBlock;
    unsigned y_block_work_begin = y_block_work_id * YPerBlock;
    unsigned x_block_work_begin = x_block_work_id * XPerBlock;

    unsigned ho_block_work_begin = y_block_work_begin * OutTileSizeH;
    unsigned wo_block_work_begin = x_block_work_begin * OutTileSizeW;

    unsigned hi_block_work_begin = ho_block_work_begin; // minus padding
    unsigned wi_block_work_begin = wo_block_work_begin; // minus padding

#if 0
    if(threadIdx.x == 0)
    {
        print_ConstantTensorDescriptor( in_desc, "gridwise_convolution:  in_desc: ");
        print_ConstantTensorDescriptor(wei_desc, "gridwise_convolution: wei_desc: ");
        print_ConstantTensorDescriptor(out_desc, "gridwise_convolution: out_desc: ");
        print_ConstantTensorDescriptor( in_block_glb_desc, "gridwise_convolution:  in_block_glb_desc: ");
        print_ConstantTensorDescriptor(wei_block_glb_desc, "gridwise_convolution: wei_block_glb_desc: ");
        print_ConstantTensorDescriptor(out_block_glb_desc, "gridwise_convolution: out_block_glb_desc: ");
        print_ConstantTensorDescriptor( in_block_lds_desc, "gridwise_convolution:  in_block_lds_desc: ");
        print_ConstantTensorDescriptor(wei_block_lds_desc, "gridwise_convolution: wei_block_lds_desc: ");
        print_ConstantTensorDescriptor(out_block_lds_desc, "gridwise_convolution: out_block_lds_desc: ");

        printf("NBlockWork %u, KBlockWork %u, YBlockWork %u, XBlockWork %u \t"
               "block_id %u, n_block_work_id %u, k_block_work_id %u, y_block_work_id %u, "
               "x_block_work_id %u\n",
               NBlockWork,
               KBlockWork,
               YBlockWork,
               XBlockWork,
               block_id,
               n_block_work_id,
               k_block_work_id,
               y_block_work_id,
               x_block_work_id);
    }
#endif

    auto f_set0 = [](TFloat& v) { v = TFloat(0); };
    auto f_copy = [](const TFloat& src, TFloat& dst) { dst = src; };
    auto f_accu = [](const TFloat& src, TFloat& dst) { dst += src; };

    // set output tensor in LDS to 0
    blockwise_4d_tensor_op_unary<TFloat,
                                 decltype(out_block_lds_desc),
                                 NBlockOpLen0,
                                 NBlockOpLen1,
                                 NBlockOpLen2,
                                 NBlockOpLen3,
                                 decltype(f_set0),
                                 BlockSize>(out_block_lds_desc, p_out_block_lds, f_set0);

    for(unsigned c_block_work_begin = 0; c_block_work_begin < in_desc.GetLength(I1);
        c_block_work_begin += CPerBlock)
    {

        // copy input tensor to LDS
        blockwise_4d_tensor_op_binary<TFloat,
                                      decltype(in_block_glb_desc),
                                      decltype(in_block_lds_desc),
                                      NBlockOpLen0,
                                      NBlockOpLen1,
                                      NBlockOpLen2,
                                      NBlockOpLen3,
                                      decltype(f_copy),
                                      BlockSize>(
            in_block_glb_desc,
            p_in_glb + in_block_glb_desc.Get1dIndex(n_block_work_begin,
                                                    c_block_work_begin,
                                                    hi_block_work_begin,
                                                    wi_block_work_begin),
            in_block_lds_desc,
            p_in_block_lds,
            f_copy);

        // copy weight tensor to LDS
        blockwise_4d_tensor_op_binary<TFloat,
                                      decltype(wei_block_glb_desc),
                                      decltype(wei_block_lds_desc),
                                      NBlockOpLen0,
                                      NBlockOpLen1,
                                      NBlockOpLen2,
                                      NBlockOpLen3,
                                      decltype(f_copy),
                                      BlockSize>(
            wei_block_glb_desc,
            p_wei_glb + wei_block_glb_desc.Get1dIndex(k_block_work_begin, c_block_work_begin, 0, 0),
            wei_block_lds_desc,
            p_wei_block_lds,
            f_copy);

#if 1
        __syncthreads();
#endif

        // blockwise convolution
        blockwise_convolution<TFloat,
                              decltype(in_block_lds_desc),
                              decltype(wei_block_lds_desc),
                              decltype(out_block_lds_desc),
                              OutTileSizeH,
                              OutTileSizeW,
                              BlockSize>(in_block_lds_desc,
                                         p_in_block_lds,
                                         wei_block_lds_desc,
                                         p_wei_block_lds,
                                         out_block_lds_desc,
                                         p_out_block_lds);

#if 1
        __syncthreads();
#endif
    }

    // copy output tensor from LDS to device mem
    blockwise_4d_tensor_op_binary<TFloat,
                                  decltype(out_block_lds_desc),
                                  decltype(out_block_glb_desc),
                                  NBlockOpLen0,
                                  NBlockOpLen1,
                                  NBlockOpLen2,
                                  NBlockOpLen3,
                                  decltype(f_copy),
                                  BlockSize>(
        out_block_lds_desc,
        p_out_block_lds,
        out_block_glb_desc,
        p_out_glb +
            out_block_glb_desc.Get1dIndex(
                n_block_work_begin, k_block_work_begin, ho_block_work_begin, wo_block_work_begin),
        f_copy);
}
