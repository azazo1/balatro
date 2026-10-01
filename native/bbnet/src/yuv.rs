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
//!
//! 系数和为 256 的整数近似, 输入在 0..=255 时结果落在 16..=235 (Y) 与 16..=240 (U/V),
//! 不会越出 u8, 所以不需要再夹取值. i32 的 `>>` 是算术右移, 负数向下取整.

/// NV12 缓冲需要的字节数 (Y 平面 + 半高的 UV 平面), 宽或高为 0 时为 0.
pub fn nv12_size(width: usize, height: usize) -> usize {
    width * height + width * (height / 2)
}

/// Y = 16 + (66R + 129G + 25B) / 256
fn luma(r: i32, g: i32, b: i32) -> u8 {
    (16 + ((66 * r + 129 * g + 25 * b) >> 8)) as u8
}

/// U = 128 + (-38R - 74G + 112B) / 256, V = 128 + (112R - 94G - 18B) / 256
fn chroma(r: i32, g: i32, b: i32) -> [u8; 2] {
    [
        (128 + ((-38 * r - 74 * g + 112 * b) >> 8)) as u8,
        (128 + ((112 * r - 94 * g - 18 * b) >> 8)) as u8,
    ]
}

/// 把 RGBA8 转成 NV12.
///
/// `rgba` 每行 `rgba_stride` 字节, 每行前 `width` 个像素有效; `dst` 先是
/// `y_stride * height` 的 Y 平面, 之后是 `uv_stride * (height / 2)` 的 UV 平面.
/// 两边的跨度都允许大于宽度 (画布和内部分配常有对齐填充), 填充字节不读也不写.
///
/// `width` 与 `height` 必须是偶数, 色度按 2x2 块取值.
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
    // UV 每行是 width / 2 对交错的 U, V, 正好 width 字节, 所以两个平面的跨度下限都是 width.
    if y_stride < width || uv_stride < width {
        return Err("输出行跨度太小");
    }
    if dst.len() < y_stride * height + uv_stride * (height / 2) {
        return Err("输出缓冲太小");
    }

    let (y_plane, uv_plane) = dst.split_at_mut(y_stride * height);
    let row_bytes = width * 4;

    for row in 0..height {
        let src = &rgba[row * rgba_stride..][..row_bytes];
        let y_row = &mut y_plane[row * y_stride..][..width];
        for (out, p) in y_row.iter_mut().zip(src.as_chunks::<4>().0) {
            *out = luma(p[0].into(), p[1].into(), p[2].into());
        }
    }

    for row in 0..height / 2 {
        let top = &rgba[2 * row * rgba_stride..][..row_bytes];
        let bottom = &rgba[(2 * row + 1) * rgba_stride..][..row_bytes];
        let uv_row = &mut uv_plane[row * uv_stride..][..width];
        let blocks = top.as_chunks::<8>().0.iter().zip(bottom.as_chunks::<8>().0);
        for (uv, (a, b)) in uv_row.as_chunks_mut::<2>().0.iter_mut().zip(blocks) {
            // 2x2 平均: 上下两行各取左右两个像素, 同一分量求和后除以 4.
            let avg = |c: usize| {
                (i32::from(a[c]) + i32::from(a[c + 4]) + i32::from(b[c]) + i32::from(b[c + 4])) / 4
            };
            *uv = chroma(avg(0), avg(1), avg(2));
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

    const RED: [u8; 4] = [255, 0, 0, 255];
    const BLUE: [u8; 4] = [0, 0, 255, 255];

    /// 转换一张紧凑排列 (跨度等于宽度) 的图像, 缓冲按 nv12_size 分配.
    fn convert(pixels: &[[u8; 4]], w: usize, h: usize) -> Vec<u8> {
        let mut out = vec![0u8; nv12_size(w, h)];
        rgba_to_nv12(pixels.as_flattened(), w, h, w * 4, &mut out, w, w).expect("转换应成功");
        out
    }

    /// 期望值取 BT.601 有限范围的理想值.
    #[test]
    fn bt601_limited_range_primaries() {
        let cases = [
            ([0, 0, 0], [16, 128, 128]),
            ([255, 255, 255], [235, 128, 128]),
            ([255, 0, 0], [81, 90, 240]),
            ([0, 255, 0], [145, 54, 34]),
            ([0, 0, 255], [41, 240, 110]),
        ];
        for ([r, g, b], [y, u, v]) in cases {
            let out = convert(&[[r, g, b, 255]; 4], 2, 2);
            assert!(out[..4].iter().all(|&got| near(got, y)), "({r},{g},{b}) 的 Y: {:?}", &out[..4]);
            assert!(near(out[4], u) && near(out[5], v), "({r},{g},{b}) 的 UV: {:?}", &out[4..]);
        }
    }

    #[test]
    fn chroma_averages_the_2x2_block() {
        // 左红右蓝: U=(90+240)/2=165, V=(240+110)/2=175.
        let out = convert(&[RED, BLUE, RED, BLUE], 2, 2);
        assert!(near(out[4], 165) && near(out[5], 175), "UV 应取平均: {:?}", &out[4..]);
    }

    #[test]
    fn honours_strides_larger_than_width() {
        // 2x4, 上两行红下两行蓝. 输入行尾填充 0x7F 不能被当成像素, 输出填充 0xAB 不能被写.
        let (w, h, stride, ys, us) = (2, 4, 12, 3, 5);
        let mut rgba = vec![0x7Fu8; stride * h];
        for row in 0..h {
            let px = if row < 2 { RED } else { BLUE };
            rgba[row * stride..][..8].copy_from_slice(&[px, px].concat());
        }
        let mut out = vec![0xABu8; ys * h + us * (h / 2)];
        rgba_to_nv12(&rgba, w, h, stride, &mut out, ys, us).expect("转换应成功");
        let (y_plane, uv) = out.split_at(ys * h);
        for row in 0..h {
            let want = if row < 2 { 81 } else { 41 };
            let y_row = &y_plane[row * ys..][..ys];
            assert!(
                near(y_row[0], want) && near(y_row[1], want) && y_row[2] == 0xAB,
                "Y 第 {row} 行: {y_row:?}"
            );
        }
        assert!(near(uv[0], 90) && near(uv[1], 240), "UV 第一行应是红: {:?}", &uv[..us]);
        assert!(near(uv[us], 240) && near(uv[us + 1], 110), "UV 第二行应是蓝: {:?}", &uv[us..]);
        let untouched = uv[2..us].iter().chain(&uv[us + 2..]).all(|&b| b == 0xAB);
        assert!(untouched, "UV 的填充不该被写: {uv:?}");
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
}
