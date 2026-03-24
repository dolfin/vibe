import SwiftUI

// MARK: - Data model

struct Acknowledgment: Identifiable {
    let id = UUID()
    let name: String
    let version: String?
    let license: String
    let url: String
    let authors: String
    let licenseText: String
}

// MARK: - License texts

private let mitLicense = { (year: String, holders: String) -> String in
    """
    MIT License

    Copyright (c) \(year) \(holders)

    Permission is hereby granted, free of charge, to any person obtaining a copy \
    of this software and associated documentation files (the "Software"), to deal \
    in the Software without restriction, including without limitation the rights \
    to use, copy, modify, merge, publish, distribute, sublicense, and/or sell \
    copies of the Software, and to permit persons to whom the Software is \
    furnished to do so, subject to the following conditions:

    The above copyright notice and this permission notice shall be included in all \
    copies or substantial portions of the Software.

    THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR \
    IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY, \
    FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE \
    AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER \
    LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM, \
    OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN THE \
    SOFTWARE.
    """
}

private let mitOrApache = { (holders: String) -> String in
    """
    Licensed under either of:

      • Apache License, Version 2.0
        https://www.apache.org/licenses/LICENSE-2.0

      • MIT License
        https://opensource.org/licenses/MIT

    at your option.

    Copyright (c) \(holders)

    Unless required by applicable law or agreed to in writing, software distributed \
    under the License is distributed on an "AS IS" BASIS, WITHOUT WARRANTIES OR \
    CONDITIONS OF ANY KIND, either express or implied. See the License for the \
    specific language governing permissions and limitations under the License.
    """
}

private let bsd3License = { (year: String, holders: String) -> String in
    """
    BSD 3-Clause License

    Copyright (c) \(year) \(holders)
    All rights reserved.

    Redistribution and use in source and binary forms, with or without \
    modification, are permitted provided that the following conditions are met:

    1. Redistributions of source code must retain the above copyright notice, \
       this list of conditions and the following disclaimer.

    2. Redistributions in binary form must reproduce the above copyright notice, \
       this list of conditions and the following disclaimer in the documentation \
       and/or other materials provided with the distribution.

    3. Neither the name of the copyright holder nor the names of its contributors \
       may be used to endorse or promote products derived from this software \
       without specific prior written permission.

    THIS SOFTWARE IS PROVIDED BY THE COPYRIGHT HOLDERS AND CONTRIBUTORS "AS IS" \
    AND ANY EXPRESS OR IMPLIED WARRANTIES, INCLUDING, BUT NOT LIMITED TO, THE \
    IMPLIED WARRANTIES OF MERCHANTABILITY AND FITNESS FOR A PARTICULAR PURPOSE ARE \
    DISCLAIMED. IN NO EVENT SHALL THE COPYRIGHT HOLDER OR CONTRIBUTORS BE LIABLE \
    FOR ANY DIRECT, INDIRECT, INCIDENTAL, SPECIAL, EXEMPLARY, OR CONSEQUENTIAL \
    DAMAGES (INCLUDING, BUT NOT LIMITED TO, PROCUREMENT OF SUBSTITUTE GOODS OR \
    SERVICES; LOSS OF USE, DATA, OR PROFITS; OR BUSINESS INTERRUPTION) HOWEVER \
    CAUSED AND ON ANY THEORY OF LIABILITY, WHETHER IN CONTRACT, STRICT LIABILITY, \
    OR TORT (INCLUDING NEGLIGENCE OR OTHERWISE) ARISING IN ANY WAY OUT OF THE USE \
    OF THIS SOFTWARE, EVEN IF ADVISED OF THE POSSIBILITY OF SUCH DAMAGE.
    """
}

private let mpl2License = { (holders: String) -> String in
    """
    Mozilla Public License Version 2.0

    Copyright (c) \(holders)

    This Source Code Form is subject to the terms of the Mozilla Public License, \
    v. 2.0. If a copy of the MPL was not distributed with this file, You can \
    obtain one at https://mozilla.org/MPL/2.0/.

    If it is not possible or desirable to put the notice in a particular file, \
    then You may include the notice in a location (such as a LICENSE file in a \
    relevant directory) where a recipient would be likely to look for such a notice.
    """
}

// MARK: - Acknowledgments data

extension Acknowledgment {
    static let all: [Acknowledgment] = [
        // Swift / macOS
        Acknowledgment(
            name: "ZIPFoundation",
            version: "0.9",
            license: "MIT",
            url: "https://github.com/weichsel/ZIPFoundation",
            authors: "Thomas Zoechling",
            licenseText: mitLicense("2017", "Thomas Zoechling")
        ),
        Acknowledgment(
            name: "Yams",
            version: "5.0",
            license: "MIT",
            url: "https://github.com/jpsim/Yams",
            authors: "JP Simard, Norio Nomura, Thibault Wittemberg",
            licenseText: mitLicense("2016", "JP Simard, Norio Nomura, Thibault Wittemberg")
        ),
        Acknowledgment(
            name: "Sparkle",
            version: "2.6",
            license: "MIT",
            url: "https://github.com/sparkle-project/Sparkle",
            authors: "Sparkle Project, Andy Matuschak",
            licenseText: mitLicense("2006", "Andy Matuschak and contributors")
        ),
        Acknowledgment(
            name: "Argon2Swift",
            version: nil,
            license: "MIT",
            url: "https://github.com/tmthecoder/Argon2Swift",
            authors: "Nikhil Nigade",
            licenseText: mitLicense("2021", "Nikhil Nigade")
        ),
        // Rust
        Acknowledgment(
            name: "serde",
            version: "1",
            license: "MIT / Apache-2.0",
            url: "https://github.com/serde-rs/serde",
            authors: "Erick Tryzelaar, David Tolnay",
            licenseText: mitOrApache("Erick Tryzelaar and David Tolnay")
        ),
        Acknowledgment(
            name: "serde_json",
            version: "1",
            license: "MIT / Apache-2.0",
            url: "https://github.com/serde-rs/json",
            authors: "Erick Tryzelaar, David Tolnay",
            licenseText: mitOrApache("Erick Tryzelaar and David Tolnay")
        ),
        Acknowledgment(
            name: "serde_yaml",
            version: "0.9",
            license: "MIT / Apache-2.0",
            url: "https://github.com/dtolnay/serde-yaml",
            authors: "David Tolnay",
            licenseText: mitOrApache("David Tolnay")
        ),
        Acknowledgment(
            name: "anyhow",
            version: "1",
            license: "MIT / Apache-2.0",
            url: "https://github.com/dtolnay/anyhow",
            authors: "David Tolnay",
            licenseText: mitOrApache("David Tolnay")
        ),
        Acknowledgment(
            name: "thiserror",
            version: "2",
            license: "MIT / Apache-2.0",
            url: "https://github.com/dtolnay/thiserror",
            authors: "David Tolnay",
            licenseText: mitOrApache("David Tolnay")
        ),
        Acknowledgment(
            name: "clap",
            version: "4",
            license: "MIT / Apache-2.0",
            url: "https://github.com/clap-rs/clap",
            authors: "clap-rs contributors",
            licenseText: mitOrApache("clap-rs contributors")
        ),
        Acknowledgment(
            name: "semver",
            version: "1",
            license: "MIT / Apache-2.0",
            url: "https://github.com/dtolnay/semver",
            authors: "Steve Klabnik, David Tolnay",
            licenseText: mitOrApache("Steve Klabnik and David Tolnay")
        ),
        Acknowledgment(
            name: "sha2",
            version: "0.10",
            license: "MIT / Apache-2.0",
            url: "https://github.com/RustCrypto/hashes",
            authors: "RustCrypto Developers",
            licenseText: mitOrApache("RustCrypto Developers")
        ),
        Acknowledgment(
            name: "aes-gcm",
            version: "0.10",
            license: "MIT / Apache-2.0",
            url: "https://github.com/RustCrypto/AEADs",
            authors: "RustCrypto Developers",
            licenseText: mitOrApache("RustCrypto Developers")
        ),
        Acknowledgment(
            name: "argon2",
            version: "0.5",
            license: "MIT / Apache-2.0",
            url: "https://github.com/RustCrypto/password-hashes",
            authors: "RustCrypto Developers",
            licenseText: mitOrApache("RustCrypto Developers")
        ),
        Acknowledgment(
            name: "ed25519-dalek",
            version: "2",
            license: "BSD-3-Clause",
            url: "https://github.com/dalek-cryptography/curve25519-dalek",
            authors: "Isis Agora Lovecruft, Henry de Valence",
            licenseText: bsd3License("2017–2019", "Isis Agora Lovecruft and Henry de Valence")
        ),
        Acknowledgment(
            name: "rand",
            version: "0.8",
            license: "MIT / Apache-2.0",
            url: "https://github.com/rust-random/rand",
            authors: "The Rand Project Developers",
            licenseText: mitOrApache("The Rand Project Developers")
        ),
        Acknowledgment(
            name: "zip",
            version: "2",
            license: "MIT",
            url: "https://github.com/zip-rs/zip2",
            authors: "Mathijs van de Nes, Marli Frost, Ryan Dens",
            licenseText: mitLicense("2014", "Mathijs van de Nes")
        ),
        Acknowledgment(
            name: "colored",
            version: "2",
            license: "MPL-2.0",
            url: "https://github.com/colored-rs/colored",
            authors: "Thomas Wickham",
            licenseText: mpl2License("Thomas Wickham")
        ),
        Acknowledgment(
            name: "chrono",
            version: "0.4",
            license: "MIT / Apache-2.0",
            url: "https://github.com/chronotope/chrono",
            authors: "Kang Seonghoon and contributors",
            licenseText: mitOrApache("Kang Seonghoon and contributors")
        ),
        Acknowledgment(
            name: "rpassword",
            version: "7",
            license: "MIT",
            url: "https://github.com/conradkleinespel/rpassword",
            authors: "Conrad Kleinespel",
            licenseText: mitLicense("2014", "Conrad Kleinespel")
        ),
        Acknowledgment(
            name: "clap_mangen",
            version: "0.2",
            license: "MIT / Apache-2.0",
            url: "https://github.com/clap-rs/clap",
            authors: "clap-rs contributors",
            licenseText: mitOrApache("clap-rs contributors")
        ),
    ]
}

// MARK: - View

struct AcknowledgmentsView: View {
    @State private var selection: Acknowledgment.ID?

    private var selectedItem: Acknowledgment? {
        Acknowledgment.all.first { $0.id == selection }
    }

    var body: some View {
        NavigationSplitView {
            List(Acknowledgment.all, selection: $selection) { item in
                VStack(alignment: .leading, spacing: 2) {
                    HStack {
                        Text(item.name)
                            .fontWeight(.medium)
                        if let version = item.version {
                            Text("v\(version)")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                        Spacer()
                    }
                    Text(item.license)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                .padding(.vertical, 2)
            }
            .navigationSplitViewColumnWidth(min: 180, ideal: 210)
        } detail: {
            if let item = selectedItem {
                LicenseDetailView(item: item)
            } else {
                Text("Select a library")
                    .foregroundStyle(.tertiary)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .onAppear {
            selection = Acknowledgment.all.first?.id
        }
    }
}

// MARK: - Detail

private struct LicenseDetailView: View {
    let item: Acknowledgment

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                // Header
                VStack(alignment: .leading, spacing: 4) {
                    HStack(alignment: .firstTextBaseline, spacing: 8) {
                        Text(item.name)
                            .font(.title2)
                            .fontWeight(.semibold)
                        if let version = item.version {
                            Text("v\(version)")
                                .font(.callout)
                                .foregroundStyle(.secondary)
                        }
                    }
                    Text(item.authors)
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                    Link(item.url, destination: URL(string: item.url)!)
                        .font(.subheadline)
                }

                Divider()

                // License badge
                Text(item.license)
                    .font(.caption)
                    .fontWeight(.medium)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 3)
                    .background(.quaternary, in: RoundedRectangle(cornerRadius: 4))
                    .foregroundStyle(.secondary)

                // License text
                Text(item.licenseText)
                    .font(.system(.caption, design: .monospaced))
                    .foregroundStyle(.secondary)
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .padding(20)
        }
        .navigationSplitViewColumnWidth(min: 360, ideal: 480)
    }
}

#Preview {
    AcknowledgmentsView()
        .frame(width: 700, height: 480)
}
