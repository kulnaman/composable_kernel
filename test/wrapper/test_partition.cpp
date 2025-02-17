// SPDX-License-Identifier: MIT
// Copyright (c) 2023-2024, Advanced Micro Devices, Inc. All rights reserved.

#include <numeric>
#include <cstdlib>
#include <iostream>
#include <initializer_list>
#include <vector>
#include <gtest/gtest.h>

#include "ck/host_utility/kernel_launch.hpp"
#include "ck/library/utility/device_memory.hpp"
#include "ck/library/utility/check_err.hpp"
#include "ck/utility/common_header.hpp"
#include "ck/wrapper/layout.hpp"
#include "ck/wrapper/tensor.hpp"

TEST(TestPartition, LocalPartition)
{
    const auto shape =
        ck::make_tuple(ck::make_tuple(ck::Number<16>{}, ck::Number<4>{}), ck::Number<4>{});
    const auto strides =
        ck::make_tuple(ck::make_tuple(ck::Number<1>{}, ck::Number<16>{}), ck::Number<64>{});
    const auto layout = ck::wrapper::make_layout(shape, strides);

    std::vector<ck::index_t> data(ck::wrapper::size(layout));
    std::iota(data.begin(), data.end(), 0);

    const auto tensor =
        ck::wrapper::make_tensor<ck::wrapper::MemoryTypeEnum::Generic>(data.data(), layout);

    const auto thread_steps  = ck::make_tuple(ck::Number<8>{}, ck::Number<1>{});
    const auto thread_layout = ck::make_tuple(ck::Number<8>{}, ck::Number<1>{});

    for(ck::index_t thread_id = 0; thread_id < ck::wrapper::size(thread_layout); thread_id++)
    {
        const auto packed_partition =
            ck::wrapper::make_local_partition(tensor, thread_layout, thread_id);

        const auto expected_partition_size =
            ck::wrapper::size(tensor) / ck::wrapper::size(thread_layout);
        const auto expected_partition_first_val  = thread_id * ck::wrapper::size<0>(thread_steps);
        const auto expected_partition_second_val = expected_partition_first_val + 1;
        EXPECT_EQ(ck::wrapper::size(packed_partition), expected_partition_size);
        EXPECT_EQ(packed_partition(0), expected_partition_first_val);
        EXPECT_EQ(packed_partition(1), expected_partition_second_val);
    }
}

TEST(TestPartition, LocalTile)
{
    const auto shape   = ck::make_tuple(ck::Number<16>{}, ck::Number<4>{}, ck::Number<4>{});
    const auto strides = ck::make_tuple(ck::Number<1>{}, ck::Number<16>{}, ck::Number<64>{});
    const auto layout  = ck::wrapper::make_layout(shape, strides);

    std::vector<ck::index_t> data(ck::wrapper::size(layout));
    std::iota(data.begin(), data.end(), 0);

    const auto tensor =
        ck::wrapper::make_tensor<ck::wrapper::MemoryTypeEnum::Generic>(data.data(), layout);

    const auto block_shape = ck::make_tuple(ck::Number<2>{}, ck::Number<4>{}, ck::Number<2>{});
    const auto num_blocks =
        ck::make_tuple(ck::wrapper::size<0>(shape) / ck::wrapper::size<0>(block_shape),
                       ck::wrapper::size<1>(shape) / ck::wrapper::size<1>(block_shape),
                       ck::wrapper::size<2>(shape) / ck::wrapper::size<2>(block_shape));
    std::vector<ck::index_t> block_idxs(ck::wrapper::size(num_blocks));
    std::iota(block_idxs.begin(), block_idxs.end(), 0);

    for(auto block_idx : block_idxs)
    {
        const auto packed_tile = ck::wrapper::make_local_tile(tensor, block_shape, block_idx);

        const auto expected_tile_size = ck::wrapper::size(block_shape);
        auto expected_tile_first_val  = (block_idx % ck::wrapper::size<2>(num_blocks)) *
                                       ck::wrapper::size<2>(block_shape) *
                                       ck::wrapper::size<2>(strides);
        block_idx /= ck::wrapper::size<2>(num_blocks);
        expected_tile_first_val += (block_idx % ck::wrapper::size<1>(num_blocks)) *
                                   ck::wrapper::size<1>(block_shape) *
                                   ck::wrapper::size<1>(strides);
        block_idx /= ck::wrapper::size<1>(num_blocks);
        expected_tile_first_val += (block_idx % ck::wrapper::size<0>(num_blocks)) *
                                   ck::wrapper::size<0>(block_shape) *
                                   ck::wrapper::size<0>(strides);

        const auto expected_tile_second_val = expected_tile_first_val + 1;
        EXPECT_EQ(ck::wrapper::size(packed_tile), expected_tile_size);
        EXPECT_EQ(packed_tile(0), expected_tile_first_val);
        EXPECT_EQ(packed_tile(1), expected_tile_second_val);
    }
}
