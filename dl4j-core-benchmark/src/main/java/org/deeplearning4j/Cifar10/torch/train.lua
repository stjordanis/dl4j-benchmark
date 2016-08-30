--
--The MIT License (MIT)
--
--Copyright (c) 2015 Sergey Zagoruyko
--
--Permission is hereby granted, free of charge, to any person obtaining a copy
--of this software and associated documentation files (the "Software"), to deal
--in the Software without restriction, including without limitation the rights
--to use, copy, modify, merge, publish, distribute, sublicense, and/or sell
--copies of the Software, and to permit persons to whom the Software is
--furnished to do so, subject to the following conditions:
--
--The above copyright notice and this permission notice shall be included in all
--copies or substantial portions of the Software.
--
--THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
--IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
--FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE
--AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
--LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM,
--OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN THE
--SOFTWARE.
--
-- Reference: https://github.com/szagoruyko/cifar.torch

require 'xlua'
require 'optim'
require 'nn'
main_path='dl4j-core-benchmark/src/main/java/org/deeplearning4j/Cifar10/torch/'

dofile 'dl4j-core-benchmark/src/main/java/org/deeplearning4j/Cifar10/torch/provider.lua'
local c = require 'trepl.colorize'

opt = lapp[[
   -s,--save                  (default "logs")      subdirectory to save logs
   -b,--batchSize             (default 128)          batch size
   -r,--learningRate          (default 1)        learning rate
   --learningRateDecay        (default 1e-7)      learning rate decay
   --weightDecay              (default 0.0005)      weightDecay
   -m,--momentum              (default 0.9)         momentum
   --epoch_step               (default 25)          epoch step
   --model                    (default vgg_bn_model)     model name
   --max_epoch                (default 300)           maximum number of iterations
   --backend                  (default nn)            backend
   --type                     (default cuda)          cuda/float/cl
   --nGPU                     (default 1)             number of gpus
]]

print(opt)

do -- data augmentation module
local BatchFlip,parent = torch.class('nn.BatchFlip', 'nn.Module')

function BatchFlip:__init()
    parent.__init(self)
    self.train = true
end

function BatchFlip:updateOutput(input)
    if self.train then
        local bs = input:size(1)
        local flip_mask = torch.randperm(bs):le(bs/2)
        for i=1,input:size(1) do
            if flip_mask[i] == 1 then image.hflip(input[i], input[i]) end
        end
    end
    self.output:set(input)
    return self.output
end
end

local function cast(t)
    if opt.type == 'cuda' then
        require 'cunn'
        return t:cuda()
    elseif opt.type == 'float' then
        return t:float()
    elseif opt.type == 'cl' then
        require 'clnn'
        return t:cl()
    else
        error('Unknown type '..opt.type)
    end
end

function makeDataParallelTable(model, nGPU)
    local net = model
    local dpt = nn.DataParallelTable(1, opt.flatten, opt.useNccl)
    for i = 1, nGPU do
        cutorch.withDevice(i, function()
            dpt:add(net:clone(), i)
        end)
        dpt.gradInput = nil
        model = dpt:cuda()
    end
    return model
end

print(c.blue '==>' ..' configuring model')
local model = nn.Sequential()
model:add(nn.BatchFlip():float())
model:add(cast(nn.Copy('torch.FloatTensor', torch.type(cast(torch.Tensor())))))
model:add(cast(dofile(main_path ..opt.model..'.lua')))
model:get(2).updateGradInput = function(input) return end

if opt.backend == 'cudnn' then
    require 'cunn'
    local cudnn = require 'cudnn'
    cudnn.convert(model:get(opt.nGPU), cudnn)
    cudnn.verbose = false
    cudnn.benchmark = true
    if opt.cudnn_fastest then
        for _,v in ipairs(model:findModules'cudnn.SpatialConvolution') do v:fastest() end
    end
    if opt.cudnn_deterministic then
        model:apply(function(m) if m.setMode then m:setMode(1,1,1) end end)
    end
end
if opt.nGPU > 1 then
    model = makeDataParallelTable(model, opt.nGPU)
else
    model = applyCuda(true, model)
end

print(model)
print(c.blue '==>' ..' loading data')
if not paths.dirp(paths.concat(main_path,'provider.tz')) then
    provider = Provider()
    provider:normalize()
    torch.save(paths.concat(main_path,'provider.t7'), provider)
end
provider = torch.load(paths.concat(main_path,'provider.t7'))
provider.trainData.data = provider.trainData.data:float()
provider.testData.data = provider.testData.data:float()

confusion = optim.ConfusionMatrix(10)

print('Will save at '..opt.save)
paths.mkdir(opt.save)
testLogger = optim.Logger(paths.concat(opt.save, 'test.log'))
testLogger:setNames{'% mean class accuracy (train set)', '% mean class accuracy (test set)'}
testLogger.showPlot = false

parameters,gradParameters = model:getParameters()


print(c.blue'==>' ..' setting criterion')
criterion = cast(nn.CrossEntropyCriterion())


print(c.blue'==>' ..' configuring optimizer')
optimState = {
    learningRate = opt.learningRate,
    weightDecay = opt.weightDecay,
    momentum = opt.momentum,
    learningRateDecay = opt.learningRateDecay,
}


function train()
    model:training()
    epoch = epoch or 1

    -- drop learning rate every "epoch_step" epochs
    if epoch % opt.epoch_step == 0 then optimState.learningRate = optimState.learningRate/2 end

    print(c.blue '==>'.." online epoch # " .. epoch .. ' [batchSize = ' .. opt.batchSize .. ']')

    local targets = cast(torch.FloatTensor(opt.batchSize))
    local indices = torch.randperm(provider.trainData.data:size(1)):long():split(opt.batchSize)
    -- remove last element so that all the batches have equal size
    indices[#indices] = nil

    local tic = torch.tic()
    for t,v in ipairs(indices) do
        xlua.progress(t, #indices)

        local inputs = provider.trainData.data:index(1,v)
        targets:copy(provider.trainData.labels:index(1,v))

        local feval = function(x)
            if x ~= parameters then parameters:copy(x) end
            gradParameters:zero()

            local outputs = model:forward(inputs)
            local f = criterion:forward(outputs, targets)
            local df_do = criterion:backward(outputs, targets)
            model:backward(inputs, df_do)

            confusion:batchAdd(outputs, targets)

            return f,gradParameters
        end
        optim.sgd(feval, parameters, optimState)
    end

    confusion:updateValids()
    print(('Train accuracy: '..c.cyan'%.2f'..' %%\t time: %.2f s'):format(
        confusion.totalValid * 100, torch.toc(tic)))

    train_acc = confusion.totalValid * 100

    confusion:zero()
    epoch = epoch + 1
end


function test()
    -- disable flips, dropouts and batch normalization
    model:evaluate()
    print(c.blue '==>'.." testing")
    local bs = 125
    for i=1,provider.testData.data:size(1),bs do
        local outputs = model:forward(provider.testData.data:narrow(1,i,bs))
        confusion:batchAdd(outputs, provider.testData.labels:narrow(1,i,bs))
    end

    confusion:updateValids()
    print('Test accuracy:', confusion.totalValid * 100)

    if testLogger then
        paths.mkdir(opt.save)
        testLogger:add{train_acc, confusion.totalValid * 100}
        testLogger:style{'-','-'}
        testLogger:plot()

        if paths.filep(opt.save..'/test.log.eps') then
            local base64im
            do
                os.execute(('convert -density 200 %s/test.log.eps %s/test.png'):format(opt.save,opt.save))
                os.execute(('openssl base64 -in %s/test.png -out %s/test.base64'):format(opt.save,opt.save))
                local f = io.open(opt.save..'/test.base64')
                if f then base64im = f:read'*all' end
            end

            local file = io.open(opt.save..'/report.html','w')
            file:write(([[
      <!DOCTYPE html>
      <html>
      <body>
      <title>%s - %s</title>
      <img src="data:image/png;base64,%s">
      <h4>optimState:</h4>
      <table>
      ]]):format(opt.save,epoch,base64im))
            for k,v in pairs(optimState) do
                if torch.type(v) == 'number' then
                    file:write('<tr><td>'..k..'</td><td>'..v..'</td></tr>\n')
                end
            end
            file:write'</table><pre>\n'
            file:write(tostring(confusion)..'\n')
            file:write(tostring(model)..'\n')
            file:write'</pre></body></html>'
            file:close()
        end
    end

    -- save model every 50 epochs
    if epoch % 50 == 0 then
        local filename = paths.concat(opt.save, 'model.net')
        print('==> saving model to '..filename)
        torch.save(filename, model:get(3):clearState())
    end

    confusion:zero()
end


for i=1,opt.max_epoch do
    train()
end
test()
