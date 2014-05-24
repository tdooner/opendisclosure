require_relative 'socrata_fetcher.rb'
require 'active_record'
require 'open-uri'

# Connect and set up the sqlite database
$LOAD_PATH << '.'
ENV['DATABASE_URL'] ||= "sqlite3:#{File.dirname(__FILE__)}/db.sqlite3"
ActiveRecord::Base.establish_connection ENV['DATABASE_URL']
require_relative 'schema.rb'
Dir[File.dirname(__FILE__) + '/models/*.rb'].each { |f| require f }

URLS = {
  'Schedule A' => 'http://data.oaklandnet.com/resource/3xq4-ermg.json',
  'Schedule E' => 'http://data.oaklandnet.com/resource/bvfu-nq99.json',
  'Summary'    => 'http://data.oaklandnet.com/resource/rsxe-vvuw.json',
}.freeze

def parse_contributions(row)
  recipient = Party::Committee.where(committee_id: row['filer_id'])
                              .first_or_create(name: row['filer_naml'])

  contributor =
    case row['entity_cd']
    when 'COM', 'SCC'
      # contributor is a Committee and Cmte_ID is set. Same thing as
      # Filer_ID but some names disagree
      Party::Committee.where(committee_id: row['cmte_id'])
                      .first_or_create(name: row['tran_naml'])

    when 'IND'
      # contributor is an Individual
      full_name = row.values_at('tran_namt', 'tran_namf', 'tran_naml', 'tran_nams')
                     .join(' ')
                     .strip
      Party::Individual.where(name: full_name,
                              city: row['tran_city'],
                              state: row['tran_state'],
                              zip: row['tran_zip4'])
                       .first_or_create(employer: row['tran_emp'],
                                        occupation: row['tran_occ'])
    when 'OTH'
      # contributor is "Other"
      Party::Other.where(name: row['tran_naml'])
                  .first_or_create(city: row['tran_city'],
                                   state: row['tran_state'],
                                   zip: row['tran_zip4'])
    end

  Contribution.create(recipient: recipient,
                      contributor: contributor,
                      amount: row['tran_amt1'],
                      date: row['tran_date'])
end

def parse_payments(row)
  payer = Party::Committee.where(committee_id: row['filer_id'])
                          .first_or_create(name: row['filer_naml'])
  recipient =
    case row['entity_cd']
    when 'COM', 'SCC'
      # entity being paid is a Committee and Cmte_ID will be set. Same thing as
      # Filer_ID but some names disagree
      Party::Committee.where(committee_id: row['cmte_id'])
                      .first_or_create(name: row['payee_naml'])

    when 'IND'
      # entity being paid is an Individual
      full_name = row.values_at('payee_namt', 'payee_naml', 'payee_namf', 'payee_nams')
                     .join(' ')
                     .strip
      Party::Individual.where(name: full_name,
                              city: row['payee_city'],
                              state: row['payee_state'],
                              zip: row['payee_zip4'])
                       .first_or_create
    when 'OTH'
      # payee is "Other"
      Party::Other.where(name: row['payee_naml'])
                  .first_or_create(city: row['payee_city'],
                                   state: row['payee_state'],
                                   zip: row['payee_zip4'])
    end

  Payment.create(payer: payer,
                 recipient: recipient,
                 amount: row['amount'],
                 date: row['expn_date'])
end

# Hash of:
# Form_Type => { Line_Item => SQL Column name }
SUMMARY_LINES = {
  'F460' => {
    '1'  => :total_monetary_contributions,
    '5'  => :total_contributions_received,
    '11' => :total_expenditures_made,
    '16' => :ending_cash_balance,
  },
  'A' => {
    '2' => :total_unitemized_contributions,
  },
}.freeze

def parse_summary(row)
  return unless SUMMARY_LINES.include? row['form_type']
  return unless SUMMARY_LINES[row['form_type']].include? row['line_item']
  return if row['filer_id'] == 'Pending' || row['filer_id'].to_i == 0

  column = SUMMARY_LINES[row['form_type']][row['line_item']]
  value = row['amount_a']

  Summary.where(party_id: row['filer_id'],
                date: row['rpt_date'].to_date)
         .first_or_create
         .update_attribute(column, value)
end

if __FILE__ == $0
  if ENV['LOG'] == "true"
    ActiveRecord::Base.logger = Logger.new(STDOUT)
  end

  puts "Fetching Contribution data (Schedule A) from Socrata:"
  Party.transaction do #        <- speed hack for sqlite3
    SocrataFetcher.new(URLS['Schedule A']).each do |record|
      parse_contributions(record)
    end
  end

  puts "Fetching Expense data (Schedule E) from Socrata:"
  Party.transaction do
    SocrataFetcher.new(URLS['Schedule E']).each do |record|
      parse_payments(record)
    end
  end

  puts "Fetching Summary data from Socrata:"
  Summary.transaction do
    SocrataFetcher.new(URLS['Summary']).each do |record|
      parse_summary(record)
    end
  end
end
