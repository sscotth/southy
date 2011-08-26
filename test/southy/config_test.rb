require 'test_helper'
require 'fileutils'
require 'yaml'

class Southy::ConfigTest < MiniTest::Spec
  
  describe 'Config' do

    before do
      @config_dir = "#{File.dirname(__FILE__)}/../../.config_test_#{rand 1000}"
      FileUtils.remove_entry_secure @config_dir if Dir.exists? @config_dir
      @config = Southy::Config.new @config_dir
    end

    describe '#init' do
      before do
        @config.init 'First', 'Last'
        @content = IO.read "#{@config_dir}/config.yml"
      end

      it 'adds the name' do
        @content.must_equal({ :first_name => 'First', :last_name => 'Last' }.to_yaml)
      end
    end

    describe '#add' do
      describe 'with name' do
        before do
          @config.add 'ABCDEF', 'First', 'Last'
          @config.add 'GHIJKL', 'One', 'Two'
          @content = IO.read "#{@config_dir}/upcoming"
        end

        it 'adds the flight' do
          @content.must_equal <<EOF
ABCDEF,First,Last,,,,
GHIJKL,One,Two,,,,
EOF
        end
      end

      describe 'without name' do
        before do
          @config.init 'First', 'Last'
          @config.add 'ABCDEF'
          @content = IO.read "#{@config_dir}/upcoming"
        end

        it 'adds the flight' do
          @content.must_equal <<EOF
ABCDEF,First,Last,,,,
EOF
        end
      end
    end

    describe '#remove' do
      before do
        @config.add 'ABCDEF', 'First', 'Last'
        @config.add 'GHIJKL', 'One', 'Two'
        @config.remove 'ABCDEF'
        @content = IO.read "#{@config_dir}/upcoming"
      end

      it 'removes the flight' do
        @content.must_equal <<EOF
GHIJKL,One,Two,,,,
EOF
      end
    end

    describe '#confirm' do
      before do
        @config.add 'ABCDEF', 'First', 'Last'
        @config.add 'GHIJKL', 'First', 'Last'
        @config.confirm( Factory.build :confirmed_flight, :confirmation_number => 'ABCDEF' )
        @content = IO.read "#{@config_dir}/upcoming"
      end

      it 'updates the flight' do
        @content.must_equal <<EOF
ABCDEF,First,Last,1234,2015-01-01T00:00:00+00:00,LAX,SFO
GHIJKL,First,Last,,,,
EOF
      end
    end

    after do
      FileUtils.remove_entry_secure @config_dir if Dir.exists? @config_dir
    end

  end
end