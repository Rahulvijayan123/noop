# Narrowly vendored code from HAR_IMU_CNN-Transformer (https://github.com/MKorp7/HAR_IMU_CNN-Transformer)
# Upstream commit: e085ac0e116aa5997d5f593ac1d0dd0c801859b1
#
# MIT License
#
# Copyright (c) 2025 MKorp7
#
# Permission is hereby granted, free of charge, to any person obtaining a copy
# of this software and associated documentation files (the "Software"), to deal
# in the Software without restriction, including without limitation the rights
# to use, copy, modify, merge, publish, distribute, sublicense, and/or sell
# copies of the Software, and to permit persons to whom the Software is
# furnished to do so, subject to the following conditions:
#
# The above copyright notice and this permission notice shall be included in all
# copies or substantial portions of the Software.
#
# THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
# IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
# FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE
# AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
# LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM,
# OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN THE
# SOFTWARE.
"""Vendored HAR_IMU_CNN-Transformer files, each byte for byte below its header (the tests check the digests).

imu_transformer.py <- src/models/imu_transformer.py (PositionalEncoding, IMUCNNTransformer): inference.
recgym_data.py     <- src/data/recgym.py (create_windows, make_loaders_for_channels): offline reproduction only.
"""
