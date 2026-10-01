//! RGBA8 到 NV12 的颜色转换, 供 Android 录像使用.
//!
//! 画面在 Lua 侧是画布读回的 RGBA8, 而 MediaCodec 的硬件编码器要 YUV420.
//! 540p 一帧有 50 万像素, 逐像素在 Lua 里转换达不到 24fps, 所以放在这里.
//! 放在 bbnet 而不是单独一个库: 这里已经有三个平台的交叉编译链路, 加一个 C 库要多养一套构建.
//!
//! 输出 NV12 (COLOR_FormatYUV420SemiPlanar): 先是 Y 平面, 之后是交错排列的 UV 平面.
//!
//! 系数用 BT.601 有限范围 (studio swing): 黑 Y=16, 白 Y=235, 色度以 128 为零点.
//! 这与 Android 相机和硬件编码器的惯例一致; 用满范围会让画面发灰或过饱和.
//! 色度按 2x2 平均抽样, 比直接取左上角像素少一些锯齿.

/// 色度平面的高度: 高度按偶数处理, 所以是 height / 2.
fn chroma_height(height: usize) -> usize {
    height / 2
}

/// NV12 缓冲需要的字节数. 尺寸非法时返回 0.
pub fn nv12_size(width: usize, height: usize) -> usize {
    if width == 0 || height == 0 {
        return 0;
    }
    width * height + width * chroma_height(height)
}

/// 整除 256 并向负无穷取整.
///
/// 直接写 `v >> 8` 在负数上是算术右移, 对这里够用, 但显式写出来更清楚, 也不依赖具体实现.
fn shr8(v: i32) -> i32 {
    if v >= 0 {
        v >> 8
    } else {
        -(((-v) + 255) >> 8)
    }
}

/// 夹到 0..=255.
fn clamp_u8(v: i32) -> u8 {
    v.clamp(0, 255) as u8
}

/// Y = 16 + (66R + 129G + 25B) / 256
fn luma(r: i32, g: i32, b: i32) -> u8 {
    clamp_u8(16 + shr8(66 * r + 129 * g + 25 * b))
}

/// U = 128 + (-38R - 74G + 112B) / 256
fn chroma_u(r: i32, g: i32, b: i32) -> u8 {
    clamp_u8(128 + shr8(-38 * r - 74 * g + 112 * b))
}

/// V = 128 + (112R - 94G - 18B) / 256
fn chroma_v(r: i32, g: i32, b: i32) -> u8 {
    clamp_u8(128 + shr8(112 * r - 94 * g - 18 * b))
}

/// 把 RGBA8 转成 NV12.
///
/// `rgba` 每行 `rgba_stride` 字节, 每行前 `width` 个像素有效; `dst` 先是
/// `y_stride * height` 的 Y 平面, 之后是 `uv_stride * (height / 2)` 的 UV 平面.
/// 两边的跨度都允许大于宽度 (画布和内部分配常有对齐填充).
///
/// `width` 与 `height` 由调用方保证是偶数 (视频编码要求, 调用方已经取过偶数).
pub fn rgba_to_nv12(
    rgba: &[u8],
    width: usize,
    height: usize,
    rgba_stride: usize,
    dst: &mut [u8],
    y_stride: usize,
    uv_stride: usize,
) -> Result<(), &'static str> {
    if width == 0 || height == 0 {
        return Err("宽高必须大于 0");
    }
    if !height.is_multiple_of(2) || !width.is_multiple_of(2) {
        return Err("宽高必须是偶数");
    }
    if rgba_stride < width * 4 {
        return Err("输入行跨度太小");
    }
    if rgba.len() < rgba_stride * (height - 1) + width * 4 {
        return Err("输入缓冲太小");
    }
    // UV 平面起点前面就是 Y 平面, 这里按 min(y_stride, width) 判断: 跨度大于宽度时多出的部分不写.
    if y_stride < width || uv_stride < width {
        return Err("输出行跨度太小");
    }
    if dst.len() < y_stride * height + uv_stride * chroma_height(height) {
        return Err("输出缓冲太小");
    }

    let (y_plane, uv_plane) = dst.split_at_mut(y_stride * height);

    for row in 0..height {
        let src = &rgba[row * rgba_stride..];
        let y_row = &mut y_plane[row * y_stride..row * y_stride + width];
        for (col, out) in y_row.iter_mut().enumerate() {
            let p = &src[col * 4..];
            *out = luma(p[0] as i32, p[1] as i32, p[2] as i32);
        }
    }

    for row in (0..height).step_by(2) {
        let src0 = &rgba[row * rgba_stride..];
        let src1 = &rgba[(row + 1) * rgba_stride..];
        let uv_row = &mut uv_plane[(row / 2) * uv_stride..(row / 2) * uv_stride + width];
        for col in (0..width).step_by(2) {
            // 2x2 平均: 相邻两行的左右各一个像素, 先各分量求和再除以 4.
            let (p0, p1) = (&src0[col * 4..], &src1[col * 4..]);
            let r = (p0[0] as i32 + p0[4] as i32 + p1[0] as i32 + p1[4] as i32) / 4;
            let g = (p0[1] as i32 + p0[5] as i32 + p1[1] as i32 + p1[5] as i32) / 4;
            let b = (p0[2] as i32 + p0[6] as i32 + p1[2] as i32 + p1[6] as i32) / 4;
            uv_row[col] = chroma_u(r, g, b);
            uv_row[col + 1] = chroma_v(r, g, b);
        }
    }
    Ok(())
}

#[cfg(test)]
mod tests {
    use super::*;

    /// 与标准值相差不超过 1: 整数换算的取整方式会带来 1 的偏差.
    fn near(got: u8, want: i32) -> bool {
        (got as i32 - want).abs() <= 1
    }

    /// 纯色图像: Y 平面处处相同, U 与 V 各一个值. 期望值取标准 BT.601 有限范围的理想值.
    fn check_colour(r: u8, g: u8, b: u8, y_want: i32, u_want: i32, v_want: i32) {
        let (w, h) = (4, 4);
        let mut rgba = vec![0u8; w * h * 4];
        for px in rgba.as_chunks_mut::<4>().0 {
            px.copy_from_slice(&[r, g, b, 255]);
        }
        let mut out = vec![0u8; nv12_size(w, h)];
        rgba_to_nv12(&rgba, w, h, w * 4, &mut out, w, w).expect("转换应成功");
        assert!(
            out[..w * h].iter().all(|&y| near(y, y_want)),
            "Y 平面应全是 {y_want}, 实际 {:?}",
            &out[..4]
        );
        assert!(near(out[w * h], u_want), "U 应为 {u_want}, 实际 {}", out[w * h]);
        assert!(near(out[w * h + 1], v_want), "V 应为 {v_want}, 实际 {}", out[w * h + 1]);
    }

    #[test]
    fn bt601_limited_range_primaries() {
        check_colour(0, 0, 0, 16, 128, 128);
        check_colour(255, 255, 255, 235, 128, 128);
        check_colour(255, 0, 0, 81, 90, 240);
        check_colour(0, 255, 0, 145, 54, 34);
        check_colour(0, 0, 255, 41, 240, 110);
    }

    #[test]
    fn chroma_rows_are_independent() {
        // 上半红下半蓝: 两行色度各自独立, 第二行在 uv_plane + uv_stride 处.
        let (w, h) = (4, 4);
        let mut rgba = vec![0u8; w * h * 4];
        for (i, px) in rgba.as_chunks_mut::<4>().0.iter_mut().enumerate() {
            let top = i / w < 2;
            px.copy_from_slice(if top { &[255, 0, 0, 255] } else { &[0, 0, 255, 255] });
        }
        let mut out = vec![0u8; nv12_size(w, h)];
        rgba_to_nv12(&rgba, w, h, w * 4, &mut out, w, w).expect("转换应成功");
        let uv = &out[w * h..];
        assert!(near(uv[0], 90) && near(uv[1], 240), "第一行应是红: {:?}", &uv[..2]);
        assert!(near(uv[w], 240) && near(uv[w + 1], 110), "第二行应是蓝: {:?}", &uv[w..w + 2]);
    }

    #[test]
    fn chroma_averages_the_2x2_block() {
        // 2x2 块内两红两蓝: U=(90+240)/2=165, V=(240+110)/2=175.
        let (w, h) = (2, 2);
        let mut rgba = vec![0u8; w * h * 4];
        for (i, px) in rgba.as_chunks_mut::<4>().0.iter_mut().enumerate() {
            let left = i % w == 0;
            px.copy_from_slice(if left { &[255, 0, 0, 255] } else { &[0, 0, 255, 255] });
        }
        let mut out = vec![0u8; nv12_size(w, h)];
        rgba_to_nv12(&rgba, w, h, w * 4, &mut out, w, w).expect("转换应成功");
        assert!(near(out[4], 165) && near(out[5], 175), "UV 应取平均: {:?}", &out[4..6]);
    }

    #[test]
    fn honours_strides_larger_than_width() {
        // 输入与输出都带对齐填充: 填充字节不能被写坏, 也不能被当成像素.
        let (w, h, stride) = (2, 2, 12);
        let mut rgba = vec![0u8; stride * h];
        for row in 0..h {
            for col in 0..w {
                let p = &mut rgba[row * stride + col * 4..row * stride + col * 4 + 4];
                p.copy_from_slice(&[255, 255, 255, 255]);
            }
        }
        // 输出跨度是 8: Y 平面 8*2, 色度平面 8*1
        let mut out = vec![0xABu8; 8 * h + 8 * (h / 2)];
        rgba_to_nv12(&rgba, w, h, stride, &mut out, 8, 8).expect("转换应成功");
        assert!(out[0] == 235 && out[1] == 235, "Y 应全是白");
        // 填充区的字节保持原样
        assert!(out[2] == 0xAB && out[3] == 0xAB, "Y 平面的填充不该被写");
    }

    #[test]
    fn rejects_bad_arguments() {
        let mut out = vec![0u8; 64];
        let rgba = vec![0u8; 64];
        assert!(rgba_to_nv12(&rgba, 0, 2, 8, &mut out, 2, 2).is_err(), "宽度为 0");
        assert!(rgba_to_nv12(&rgba, 3, 2, 12, &mut out, 3, 3).is_err(), "宽度为奇数");
        assert!(rgba_to_nv12(&rgba, 2, 3, 8, &mut out, 2, 2).is_err(), "高度为奇数");
        assert!(rgba_to_nv12(&rgba, 4, 4, 8, &mut out, 4, 4).is_err(), "输入跨度太小");
        assert!(rgba_to_nv12(&rgba, 4, 4, 16, &mut out, 2, 2).is_err(), "输出跨度太小");
        assert!(rgba_to_nv12(&rgba, 4, 4, 16, &mut out[..8], 4, 4).is_err(), "输出缓冲太小");
    }

    #[test]
    fn nv12_size_matches_planes() {
        assert_eq!(nv12_size(960, 540), 960 * 540 + 960 * 270);
        assert_eq!(nv12_size(0, 540), 0);
        assert_eq!(nv12_size(960, 0), 0);
    }
}
