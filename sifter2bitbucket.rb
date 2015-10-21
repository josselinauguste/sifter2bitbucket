require 'nokogiri'
require 'json'
require 'tmpdir'
require 'open-uri'
require 'securerandom'
require 'fileutils'

MEMBERS = {
  59211 => 'grdscrc',
  46868 => 'jdkoeck',
  46974 => 'josselinauguste',
  47145 => 'Popoche',
  47322 => 'ValentinLG'
}

PRIORITIES = {
  1 => 'blocker',
  2 => 'critical',
  3 => 'major',
  4 => 'minor',
  5 => 'trivial'
}

STATUSES = {
  1 => 'open',
  2 => 'open',
  3 => 'resolved',
  4 => 'closed'
}

class Nokogiri::XML::Element
  def t(name)
    node = xpath(name).first
    return nil if node.nil? || node.attr('nil') == 'true' || node.children.length == 0
    content = node.children.first.content
    if node.attr('type') == 'integer'
      content.to_i
    else
      content
    end
  end

  def filename
    return @filename if @filename
    f = t('filename').gsub(/[^0-9A-Za-z_\\-\\.]/, '')
    name, extension = if f == 'undefined'
      [f, t('content-type').split('/').last]
    else
      name, _, extension = f.rpartition('.')
      [name, extension]
    end
    uniqueness = SecureRandom.hex
    @filename = "#{name}_#{uniqueness}.#{extension}"
  end
end

class IssueConverter
  def initialize(issue)
    @issue = issue
  end

  def convert(components, milestones, bug_id)
    first_comment = @issue.xpath('comment').first
    watchers = @issue.xpath('comment/commenter-id/text()').map(&:content).uniq.compact.map { |c| MEMBERS[c.to_i] }
    {
      assignee: @issue.t('assignee-id') ? MEMBERS[@issue.t('assignee-id')] : nil,
      component: @issue.t('category-id') && components[@issue.t('category-id')] ? components[@issue.t('category-id')] : nil,
      content: first_comment.t('body').to_s,
      content_updated_on: first_comment.t('updated-at'),
      created_on: @issue.t('created-at'),
      edited_on: @issue.t('updated-at'),
      id: @issue.t('id'),
      kind: @issue.t('category-id') == bug_id ? 'bug' : 'task',
      milestone: @issue.t('milestone-id') && milestones[@issue.t('milestone-id')] ? milestones[@issue.t('milestone-id')] : nil,
      priority: PRIORITIES[@issue.t('priority-id')],
      reporter: MEMBERS[@issue.t('opener-id')],
      status: STATUSES[@issue.t('status-id')],
      title: @issue.t('subject'),
      updated_on: @issue.t('updated-at'),
      version: nil,
      watchers: watchers,
      voters: []
    }
  end

  def extract_comments
    @issue.xpath('comment')[1..-1].select { |c| c.t('body') }.map do |comment|
      {
        "content": comment.t('body'),
        "created_on": comment.t('created-at'),
        "id": comment.t('id'),
        "issue": @issue.t('id'),
        "updated_on": comment.t('updated-at'),
        "user": MEMBERS[comment.t('commenter-id')]
      }
    end
  end

  def extract_logs
    []
  end

  def extract_attachments(dir)
    FileUtils.mkdir_p File.join(dir, 'attachments')
    @issue.xpath('comment/attachment').map do |attachment|
      relative_target = File.join('attachments', attachment.filename)
      puts "Downloading attachment #{relative_target}..."
      open(attachment.t('url'), 'rb') do |read_file|
        File.open(File.join(dir, relative_target), 'wb') do |saved_file|
          saved_file.write(read_file.read)
        end
      end
      {
        "filename": attachment.filename,
        "issue": @issue.t('id'),
        "path": relative_target,
        "user": MEMBERS[attachment.parent.t('commenter-id')]
      }
    end
  end
end

def output(dir, bucket)
  output = File.join(dir, 'db-1.0.json')
  puts "Writing output to #{output}..."
  File.write(output, JSON.generate(bucket))
  `(cd #{dir}; zip -r ~/Desktop/issues.zip .)`
end

if __FILE__ == $PROGRAM_NAME
  dir = Dir.mktmpdir
  bucket = {
    issues: [],
    comments: [],
    attachments: [],
    logs: [],
    meta: {default_kind: 'task'},
    components: [],
    milestones: [],
    versions: []
  }
  components = {}
  milestones = {}
  bug_id = nil
  source = File.open(ARGV[0]) { |f| Nokogiri::XML(f) }
  source.xpath('//milestones/milestone').each do |milestone|
    milestones[milestone.t('id')] = milestone.t('name')
    bucket[:milestones] << { name: milestone.t('name') }
  end
  source.xpath('//categories/category').each do |category|
    if category.t('name').downcase == 'bug'
      bug_id = category.t('id')
      next
    end
    components[category.t('id')] = category.t('name')
    bucket[:components] << { name: category.t('name') }
  end
  source.xpath('//issue').each do |issue|
    converter = IssueConverter.new(issue)
    bucket[:issues] << converter.convert(components, milestones, bug_id)
    bucket[:comments].concat converter.extract_comments
    bucket[:logs].concat converter.extract_logs
    bucket[:attachments].concat converter.extract_attachments(dir)
  end
  output dir, bucket
end
