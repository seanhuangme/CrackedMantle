Pod::Spec.new do |s|
  s.name         = 'CrackedMantle'
  s.version      = '0.1.0'
  s.summary      = 'Persist Mantle models with FCModel and FMDB.'
  s.requires_arc = true
  s.authors = {
    'Justin Spahr-Summers' => 'jspahrsummers@github.com',
    'Marco Arment' => 'marco@marco.org',
    'Gus Mueller' => 'gus@flyingmeat.com',
    'Jordan Kay' => 'jordanekay@mac.com'
  }
  s.source = {
    :git => 'https://github.com/jordanekay/CrackedMantle.git',
    :tag => '0.1.0'
  }
  s.source_files = '*/*.{h,m}'
end
