/// বাংলাদেশের ৬৪ জেলা ও ৮ বিভাগ — সার্কুলারের এলাকা-শর্ত মেলানোর জন্য।
/// ব্যবহারকারীর স্থায়ী জেলা কোডে বাঁধা নয়: জব প্রোফাইল থেকে সিলেক্ট করে রাখে,
/// আর সার্কুলারের টেক্সটে এই নামগুলো খুঁজে এলাকা-শর্ত ধরা হয় (circular_parser-এর parseArea)।

class BdDistrict {
  final String key; // 'joypurhat' — সংরক্ষণে এই কী
  final String bn; // 'জয়পুরহাট'
  final String en; // 'Joypurhat'
  final String division; // বিভাগের কী
  final List<String> aliases; // বাড়তি বানান (বাংলা/ইংরেজি)
  const BdDistrict(this.key, this.bn, this.en, this.division, [this.aliases = const []]);
}

class BdDivision {
  final String key;
  final String bn;
  final String en;
  const BdDivision(this.key, this.bn, this.en);
}

const bdDivisions = <BdDivision>[
  BdDivision('dhaka', 'ঢাকা', 'Dhaka'),
  BdDivision('chattogram', 'চট্টগ্রাম', 'Chattogram'),
  BdDivision('rajshahi', 'রাজশাহী', 'Rajshahi'),
  BdDivision('khulna', 'খুলনা', 'Khulna'),
  BdDivision('barishal', 'বরিশাল', 'Barishal'),
  BdDivision('sylhet', 'সিলেট', 'Sylhet'),
  BdDivision('rangpur', 'রংপুর', 'Rangpur'),
  BdDivision('mymensingh', 'ময়মনসিংহ', 'Mymensingh'),
];

const bdDistricts = <BdDistrict>[
  // ঢাকা বিভাগ
  BdDistrict('dhaka', 'ঢাকা', 'Dhaka', 'dhaka'),
  BdDistrict('gazipur', 'গাজীপুর', 'Gazipur', 'dhaka'),
  BdDistrict('narayanganj', 'নারায়ণগঞ্জ', 'Narayanganj', 'dhaka', ['নারায়ণগঞ্জ']),
  BdDistrict('tangail', 'টাঙ্গাইল', 'Tangail', 'dhaka'),
  BdDistrict('kishoreganj', 'কিশোরগঞ্জ', 'Kishoreganj', 'dhaka'),
  BdDistrict('manikganj', 'মানিকগঞ্জ', 'Manikganj', 'dhaka'),
  BdDistrict('munshiganj', 'মুন্সিগঞ্জ', 'Munshiganj', 'dhaka', ['মুন্সীগঞ্জ']),
  BdDistrict('narsingdi', 'নরসিংদী', 'Narsingdi', 'dhaka'),
  BdDistrict('rajbari', 'রাজবাড়ী', 'Rajbari', 'dhaka'),
  BdDistrict('madaripur', 'মাদারীপুর', 'Madaripur', 'dhaka'),
  BdDistrict('gopalganj', 'গোপালগঞ্জ', 'Gopalganj', 'dhaka'),
  BdDistrict('faridpur', 'ফরিদপুর', 'Faridpur', 'dhaka'),
  BdDistrict('shariatpur', 'শরীয়তপুর', 'Shariatpur', 'dhaka'),
  // চট্টগ্রাম বিভাগ
  BdDistrict('chattogram', 'চট্টগ্রাম', 'Chattogram', 'chattogram', ['Chittagong']),
  BdDistrict('coxsbazar', 'কক্সবাজার', "Cox's Bazar", 'chattogram', ['কক্স বাজার', 'Coxs Bazar']),
  BdDistrict('bandarban', 'বান্দরবান', 'Bandarban', 'chattogram'),
  BdDistrict('rangamati', 'রাঙ্গামাটি', 'Rangamati', 'chattogram', ['রাঙামাটি']),
  BdDistrict('khagrachhari', 'খাগড়াছড়ি', 'Khagrachhari', 'chattogram'),
  BdDistrict('feni', 'ফেনী', 'Feni', 'chattogram'),
  BdDistrict('noakhali', 'নোয়াখালী', 'Noakhali', 'chattogram'),
  BdDistrict('lakshmipur', 'লক্ষ্মীপুর', 'Lakshmipur', 'chattogram', ['লক্ষীপুর']),
  BdDistrict('chandpur', 'চাঁদপুর', 'Chandpur', 'chattogram'),
  BdDistrict('cumilla', 'কুমিল্লা', 'Cumilla', 'chattogram', ['Comilla']),
  BdDistrict('brahmanbaria', 'ব্রাহ্মণবাড়িয়া', 'Brahmanbaria', 'chattogram'),
  // রাজশাহী বিভাগ
  BdDistrict('rajshahi', 'রাজশাহী', 'Rajshahi', 'rajshahi'),
  BdDistrict('bogura', 'বগুড়া', 'Bogura', 'rajshahi', ['Bogra']),
  BdDistrict('joypurhat', 'জয়পুরহাট', 'Joypurhat', 'rajshahi'),
  BdDistrict('naogaon', 'নওগাঁ', 'Naogaon', 'rajshahi', ['নওগাঁও']),
  BdDistrict('natore', 'নাটোর', 'Natore', 'rajshahi'),
  BdDistrict('chapainawabganj', 'চাঁপাইনবাবগঞ্জ', 'Chapainawabganj', 'rajshahi', ['চাঁপাই নবাবগঞ্জ', 'নবাবগঞ্জ']),
  BdDistrict('pabna', 'পাবনা', 'Pabna', 'rajshahi'),
  BdDistrict('sirajganj', 'সিরাজগঞ্জ', 'Sirajganj', 'rajshahi'),
  // খুলনা বিভাগ
  BdDistrict('khulna', 'খুলনা', 'Khulna', 'khulna'),
  BdDistrict('bagerhat', 'বাগেরহাট', 'Bagerhat', 'khulna'),
  BdDistrict('satkhira', 'সাতক্ষীরা', 'Satkhira', 'khulna'),
  BdDistrict('jashore', 'যশোর', 'Jashore', 'khulna', ['Jessore']),
  BdDistrict('jhenaidah', 'ঝিনাইদহ', 'Jhenaidah', 'khulna'),
  BdDistrict('magura', 'মাগুরা', 'Magura', 'khulna'),
  BdDistrict('narail', 'নড়াইল', 'Narail', 'khulna'),
  BdDistrict('kushtia', 'কুষ্টিয়া', 'Kushtia', 'khulna'),
  BdDistrict('chuadanga', 'চুয়াডাঙ্গা', 'Chuadanga', 'khulna'),
  BdDistrict('meherpur', 'মেহেরপুর', 'Meherpur', 'khulna'),
  // বরিশাল বিভাগ
  BdDistrict('barishal', 'বরিশাল', 'Barishal', 'barishal', ['Barisal']),
  BdDistrict('bhola', 'ভোলা', 'Bhola', 'barishal'),
  BdDistrict('patuakhali', 'পটুয়াখালী', 'Patuakhali', 'barishal'),
  BdDistrict('pirojpur', 'পিরোজপুর', 'Pirojpur', 'barishal'),
  BdDistrict('barguna', 'বরগুনা', 'Barguna', 'barishal'),
  BdDistrict('jhalokati', 'ঝালকাঠি', 'Jhalokati', 'barishal', ['ঝালকাঠী']),
  // সিলেট বিভাগ
  BdDistrict('sylhet', 'সিলেট', 'Sylhet', 'sylhet'),
  BdDistrict('moulvibazar', 'মৌলভীবাজার', 'Moulvibazar', 'sylhet'),
  BdDistrict('habiganj', 'হবিগঞ্জ', 'Habiganj', 'sylhet'),
  BdDistrict('sunamganj', 'সুনামগঞ্জ', 'Sunamganj', 'sylhet'),
  // রংপুর বিভাগ
  BdDistrict('rangpur', 'রংপুর', 'Rangpur', 'rangpur'),
  BdDistrict('dinajpur', 'দিনাজপুর', 'Dinajpur', 'rangpur'),
  BdDistrict('thakurgaon', 'ঠাকুরগাঁও', 'Thakurgaon', 'rangpur'),
  BdDistrict('panchagarh', 'পঞ্চগড়', 'Panchagarh', 'rangpur'),
  BdDistrict('nilphamari', 'নীলফামারী', 'Nilphamari', 'rangpur'),
  BdDistrict('lalmonirhat', 'লালমনিরহাট', 'Lalmonirhat', 'rangpur'),
  BdDistrict('kurigram', 'কুড়িগ্রাম', 'Kurigram', 'rangpur'),
  BdDistrict('gaibandha', 'গাইবান্ধা', 'Gaibandha', 'rangpur'),
  // ময়মনসিংহ বিভাগ
  BdDistrict('mymensingh', 'ময়মনসিংহ', 'Mymensingh', 'mymensingh'),
  BdDistrict('jamalpur', 'জামালপুর', 'Jamalpur', 'mymensingh'),
  BdDistrict('sherpur', 'শেরপুর', 'Sherpur', 'mymensingh'),
  BdDistrict('netrokona', 'নেত্রকোণা', 'Netrokona', 'mymensingh', ['নেত্রকোনা']),
];

/// পার্বত্য জেলাসমূহ — "পার্বত্য জেলা ব্যতীত" জাতীয় শর্তে লাগে।
const hillDistricts = <String>{'bandarban', 'rangamati', 'khagrachhari'};

BdDistrict? districtByKey(String key) {
  for (final d in bdDistricts) {
    if (d.key == key) return d;
  }
  return null;
}

BdDivision? divisionByKey(String key) {
  for (final d in bdDivisions) {
    if (d.key == key) return d;
  }
  return null;
}

Set<String> districtsOfDivision(String divisionKey) =>
    bdDistricts.where((d) => d.division == divisionKey).map((d) => d.key).toSet();

bool _isLatin(String s) => RegExp(r'^[A-Za-z]').hasMatch(s);

/// টেক্সটে যেসব জেলার নাম আছে তাদের কী। বাংলা নাম সরাসরি খোঁজা হয় ("ঢাকায়"-ও ধরা পড়ে),
/// ইংরেজি নাম শব্দ-সীমানা দিয়ে (যাতে অন্য শব্দের ভেতরের অংশে ভুল মিল না হয়)।
Set<String> districtsIn(String text) {
  final out = <String>{};
  for (final d in bdDistricts) {
    for (final name in [d.bn, d.en, ...d.aliases]) {
      if (name.isEmpty) continue;
      final hit = _isLatin(name)
          ? RegExp(r'\b' + RegExp.escape(name).replaceAll(r"\'", r"'?") + r'\b', caseSensitive: false).hasMatch(text)
          : text.contains(name);
      if (hit) {
        out.add(d.key);
        break;
      }
    }
  }
  return out;
}

/// টেক্সটে "X বিভাগ" / "X Division" আকারে যেসব বিভাগের উল্লেখ আছে।
List<BdDivision> divisionsIn(String text) {
  final out = <BdDivision>[];
  for (final d in bdDivisions) {
    final bnHit = RegExp('${RegExp.escape(d.bn)}\\s*বিভাগ').hasMatch(text);
    final enHit = RegExp(r'\b' + RegExp.escape(d.en) + r'\s+division\b', caseSensitive: false).hasMatch(text);
    if (bnHit || enHit) out.add(d);
  }
  return out;
}
